import Foundation
import AVFoundation

public struct AudioBuffer: Sendable {
    public let samples: [Float]          // mono float32 [-1, 1]
    public let sampleRate: Double        // 16000

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

/// Captures microphone audio, emits RMS levels in real time and returns the full
/// recording as a 16 kHz mono float32 buffer on stop.
public final class AudioCapture: @unchecked Sendable {

    public enum CaptureError: Error {
        case engineStart(Error)
        case conversionSetupFailed
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat!
    private let outputFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 16_000,
                      channels: 1,
                      interleaved: false)!
    }()

    private let accumulatorLock = NSLock()
    private var accumulator: [Float] = []

    private var levelsContinuation: AsyncStream<Float>.Continuation?

    private var startedAt: Date = .distantPast
    public let maxDuration: TimeInterval = 60.0

    public init() {}

    /// Starts the engine and returns a stream of normalized RMS levels (0...1).
    public func start() throws -> AsyncStream<Float> {
        let node = engine.inputNode
        let inFmt = node.outputFormat(forBus: 0)
        self.inputFormat = inFmt

        guard let converter = AVAudioConverter(from: inFmt, to: outputFormat) else {
            throw CaptureError.conversionSetupFailed
        }
        self.converter = converter

        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulator.reserveCapacity(Int(outputFormat.sampleRate * maxDuration))
        accumulatorLock.unlock()

        startedAt = Date()

        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.levelsContinuation = continuation

        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            levelsContinuation?.finish()
            levelsContinuation = nil
            throw CaptureError.engineStart(error)
        }

        Log.audio.info("AudioCapture started: \(inFmt.description)")
        return stream
    }

    public func stop() -> AudioBuffer {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelsContinuation?.finish()
        levelsContinuation = nil

        accumulatorLock.lock()
        let samples = accumulator
        accumulator.removeAll()
        accumulatorLock.unlock()

        Log.audio.info("AudioCapture stopped: \(samples.count) samples at 16kHz (\(Double(samples.count) / 16000.0)s)")
        return AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Tap handler

    private func handle(buffer: AVAudioPCMBuffer) {
        // Safety cap: if we're past maxDuration, don't accumulate further but keep publishing levels at zero.
        let elapsed = Date().timeIntervalSince(startedAt)
        let overLimit = elapsed > maxDuration

        let level = Self.normalizedRMS(buffer)
        levelsContinuation?.yield(level)

        guard !overLimit else { return }

        guard let converter = converter else { return }
        if let mono16k = Self.convert(buffer: buffer, with: converter, target: outputFormat) {
            accumulatorLock.lock()
            accumulator.append(contentsOf: mono16k)
            accumulatorLock.unlock()
        }
    }

    // MARK: - RMS (on native format, channel 0)

    private static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ptr = ch[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = ptr[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        // Map rms (0...1) -> dB (-inf...0) -> 0...1 over -60..0 dB
        let db = 20.0 * log10(max(rms, 1e-6))
        let norm = (db + 60.0) / 60.0
        return max(0, min(1, norm))
    }

    // MARK: - Resample / downmix to 16 kHz mono float32

    private static func convert(buffer: AVAudioPCMBuffer,
                                 with converter: AVAudioConverter,
                                 target: AVAudioFormat) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrameCapacity) else {
            return nil
        }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            Log.audio.error("AVAudioConverter error: \(error.localizedDescription)")
            return nil
        }
        if status == .error { return nil }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let ch = outBuffer.floatChannelData else { return [] }
        let ptr = ch[0]
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = ptr[i] }
        return samples
    }
}
