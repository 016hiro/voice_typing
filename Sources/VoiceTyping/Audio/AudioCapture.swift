import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

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

    public enum CaptureError: LocalizedError {
        case engineStart(Error)
        case conversionSetupFailed
        case noBuiltInInputDevice
        case audioUnitSetup(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .engineStart(let error):
                return "Audio engine start failed: \(error.localizedDescription)"
            case .conversionSetupFailed:
                return "Audio converter setup failed"
            case .noBuiltInInputDevice:
                return "Built-in microphone not found"
            case .audioUnitSetup(let operation, let status):
                return "\(operation) failed: status=\(status)"
            }
        }
    }

    private var audioUnit: AudioUnit?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
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
        guard let device = CoreAudioInputDevice.preferredBuiltInInput() else {
            throw CaptureError.noBuiltInInputDevice
        }
        let inFmt = try Self.inputFormat(for: device)

        guard let converter = AVAudioConverter(from: inFmt, to: outputFormat) else {
            throw CaptureError.conversionSetupFailed
        }
        let outputs = prepareSession(inputFormat: inFmt, converter: converter, maxDuration: maxDuration)

        do {
            try startHALInput(device: device, format: inFmt)
        } catch {
            resetSessionState()
            throw CaptureError.engineStart(error)
        }

        Log.audio.info("AudioCapture started: \(inFmt.description) device=\(device.name, privacy: .public)")
        return outputs
    }

    public func stop() -> AudioBuffer {
        stopHALInput()
        levelsContinuation?.finish()
        levelsContinuation = nil
        samplesContinuation?.finish()
        samplesContinuation = nil
        converter = nil
        inputFormat = nil

        accumulatorLock.lock()
        let samples = accumulator
        accumulator.removeAll()
        accumulatorLock.unlock()

        Log.audio.info("AudioCapture stopped: \(samples.count) samples at 16kHz (\(Double(samples.count) / 16000.0)s)")
        return AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    func prepareSession(inputFormat inFmt: AVAudioFormat,
                        converter: AVAudioConverter,
                        maxDuration: TimeInterval) -> StartOutputs {
        self.converter = converter
        inputFormat = inFmt

        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulator.reserveCapacity(Int(outputFormat.sampleRate * maxDuration))
        accumulatorLock.unlock()

        startedAt = Date()

        let (levelsStream, levelsCont) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        levelsContinuation = levelsCont

        // `.unbounded` on the samples stream: the consumer (LiveTranscriber) is
        // off the audio thread, so yields buffer briefly. At ~341 samples / 7 ms
        // tap interval × 600 s cap = ~85 K yields max if the consumer never reads —
        // not a real-world concern but worth noting in case of a bug downstream.
        let (samplesStream, samplesCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        samplesContinuation = samplesCont

        return StartOutputs(levels: levelsStream, samples: samplesStream)
    }

    var preparedInputFormatSampleRate: Double? {
        inputFormat?.sampleRate
    }

    private func resetSessionState() {
        levelsContinuation?.finish()
        levelsContinuation = nil
        samplesContinuation?.finish()
        samplesContinuation = nil
        converter = nil
        inputFormat = nil
    }

    // MARK: - CoreAudio HAL input

    private static func inputFormat(for device: CoreAudioInputDevice.Device) throws -> AVAudioFormat {
        let sampleRate = CoreAudioInputDevice.nominalSampleRate(for: device.id) ?? 48_000
        let channelCount = max(AVAudioChannelCount(1), AVAudioChannelCount(device.inputChannels))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: channelCount,
                                         interleaved: false) else {
            throw CaptureError.conversionSetupFailed
        }
        return format
    }

    private func startHALInput(device: CoreAudioInputDevice.Device, format: AVAudioFormat) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.audioUnitSetup("Find HAL output unit", -1)
        }

        var newUnit: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &newUnit), "Create HAL output unit")
        guard let unit = newUnit else {
            throw CaptureError.audioUnitSetup("Create HAL output unit", -1)
        }

        do {
            var enableInput: UInt32 = 1
            try check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &enableInput,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                "Enable HAL input"
            )

            var disableOutput: UInt32 = 0
            try check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &disableOutput,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                "Disable HAL output"
            )

            var deviceID = device.id
            try check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                "Select HAL input device"
            )

            var streamFormat = format.streamDescription.pointee
            try check(
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &streamFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                "Set HAL input stream format"
            )

            var callback = AURenderCallbackStruct(
                inputProc: halInputRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "Set HAL input callback"
            )

            try check(AudioUnitInitialize(unit), "Initialize HAL input")
            audioUnit = unit
            try check(AudioOutputUnitStart(unit), "Start HAL input")
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            throw error
        }
    }

    private func stopHALInput() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CaptureError.audioUnitSetup(operation, status)
        }
    }

    fileprivate func renderInput(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 timeStamp: UnsafePointer<AudioTimeStamp>,
                                 numberFrames: UInt32) -> OSStatus {
        guard let unit = audioUnit else {
            Log.audio.error("HAL input callback missing audio unit")
            return noErr
        }
        guard let format = inputFormat else {
            Log.audio.error("HAL input callback missing input format")
            return noErr
        }
        guard let buffer = Self.makeRenderBuffer(format: format, numberFrames: numberFrames) else {
            Log.audio.error("HAL input buffer allocation failed")
            return noErr
        }

        let status = AudioUnitRender(
            unit,
            ioActionFlags,
            timeStamp,
            1,
            numberFrames,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.audio.error("HAL input render failed: \(status, privacy: .public)")
            return status
        }

        handle(buffer: buffer)
        return noErr
    }

    static func makeRenderBuffer(format: AVAudioFormat, numberFrames: UInt32) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numberFrames) else {
            return nil
        }
        buffer.frameLength = numberFrames
        return buffer
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

private let halInputRenderCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, _, numberFrames, _ in
    let capture = Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.renderInput(
        ioActionFlags: ioActionFlags,
        timeStamp: timeStamp,
        numberFrames: numberFrames
    )
}
