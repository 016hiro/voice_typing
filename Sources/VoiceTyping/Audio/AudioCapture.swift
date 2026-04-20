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
    private var samplesContinuation: AsyncStream<[Float]>.Continuation?

    private var startedAt: Date = .distantPast
    /// Hard cap on recording length, set per-`start()`. Default 60 s (the v0.4.x
    /// batch behavior — protects against stuck Fn / buggy hotkey causing
    /// runaway recording + downstream OOM in single-shot Qwen.transcribe).
    /// Live-mic mode passes a larger value (600 s) since segments transcribe
    /// as they arrive — long sessions don't consume resources proportionally.
    public private(set) var maxDuration: TimeInterval = 60.0

    public init() {}

    public struct StartOutputs {
        /// Normalized RMS levels (0…1) emitted on the audio thread for the capsule waveform.
        public let levels: AsyncStream<Float>
        /// Converted 16 kHz mono Float32 samples, chunked at the native tap buffer rate
        /// (~341 samples per yield from a 48 kHz source). Used by `LiveTranscriber` —
        /// caller doesn't need to subscribe if not running live mode.
        public let samples: AsyncStream<[Float]>
    }

    /// Starts the engine and returns the live `levels` and `samples` streams. Both
    /// streams finish when `stop()` is called.
    /// - Parameter maxDuration: Hard cap on recording length (default 60 s).
    ///   After this, the accumulator stops growing and the samples stream stops
    ///   yielding, but levels keep emitting so the waveform stays visually alive.
    public func start(maxDuration: TimeInterval = 60.0) throws -> StartOutputs {
        self.maxDuration = maxDuration
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

        let (levelsStream, levelsCont) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.levelsContinuation = levelsCont

        // `.unbounded` on the samples stream: the consumer (LiveTranscriber) is
        // off the audio thread, so yields buffer briefly. At ~341 samples / 7 ms
        // tap interval × 600 s cap = ~85 K yields max if the consumer never reads —
        // not a real-world concern but worth noting in case of a bug downstream.
        let (samplesStream, samplesCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.samplesContinuation = samplesCont

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
            samplesContinuation?.finish()
            samplesContinuation = nil
            throw CaptureError.engineStart(error)
        }

        Log.audio.info("AudioCapture started: \(inFmt.description)")
        return StartOutputs(levels: levelsStream, samples: samplesStream)
    }

    public func stop() -> AudioBuffer {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelsContinuation?.finish()
        levelsContinuation = nil
        samplesContinuation?.finish()
        samplesContinuation = nil

        accumulatorLock.lock()
        let samples = accumulator
        accumulator.removeAll()
        accumulatorLock.unlock()

        Log.audio.info("AudioCapture stopped: \(samples.count) samples at 16kHz (\(Double(samples.count) / 16000.0)s)")
        return AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Tap handler

    private func handle(buffer: AVAudioPCMBuffer) {
        // Safety cap: if we're past maxDuration, stop accumulating + stop emitting
        // samples but keep publishing levels (waveform stays alive visually).
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
            // Live mic feed — yield to LiveTranscriber if subscribed. Cheap no-op
            // when no one's listening (continuation just buffers).
            samplesContinuation?.yield(mono16k)
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
