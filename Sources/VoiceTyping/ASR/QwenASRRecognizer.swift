import Foundation
import os
import Qwen3ASR
import SpeechVAD

/// Wraps `soniqo/speech-swift`'s `Qwen3ASRModel` behind our `SpeechRecognizer` protocol.
/// The underlying model is not thread-safe; we serialize transcribe calls here.
public final class QwenASRRecognizer: SpeechRecognizer, @unchecked Sendable {

    private let backend: ASRBackend
    private let modelId: String
    private let cacheDir: URL

    /// `Qwen3ASRModel` is a class; keep it alive for the recognizer's lifetime.
    /// Access is serialized by `transcribeLock` (async-safe).
    private var model: Qwen3ASRModel?
    private let transcribeLock = OSAllocatedUnfairLock()

    private let stateLock = NSLock()
    private var _state: RecognizerState = .unloaded
    public var state: RecognizerState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private var stateContinuation: AsyncStream<RecognizerState>.Continuation?
    public let stateStream: AsyncStream<RecognizerState>

    public init(backend: ASRBackend, cacheDir: URL) {
        precondition(backend.isQwen, "QwenASRRecognizer only supports Qwen backends")
        guard let id = backend.qwenModelId else {
            fatalError("Qwen backend \(backend.rawValue) missing modelId mapping")
        }
        self.backend = backend
        self.modelId = id
        // `Qwen3ASRModel.fromPretrained` expects `cacheDir` to point at the final per-model
        // directory (`<base>/models/<org>/<model>/`). Internally it strips that suffix to
        // derive the HubApi downloadBase. If the suffix doesn't match it falls back to
        // ~/Library/Caches/, which silently splits download (real files) from lookup
        // (vocab.json/safetensors checked under our path) and load fails.
        // So we extend the per-backend dir with the expected Hub-style suffix here.
        self.cacheDir = cacheDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)

        let (stream, cont) = AsyncStream<RecognizerState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.stateStream = stream
        self.stateContinuation = cont
    }

    deinit {
        stateContinuation?.finish()
    }

    public func prepare() async throws {
        // MLX aborts the process via a C++ exception if `mlx.metallib` isn't colocated
        // with the executable. Detect that condition before touching MLX.
        guard MLXSupport.isAvailable else {
            let err = NSError(
                domain: "VoiceTyping.ASR",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey:
                    "MLX shaders missing — run `make setup-metal` then rebuild to enable Qwen backends."
                ]
            )
            setState(.failed(err))
            throw err
        }

        // When weights are already on disk, `Qwen3ASRModel.fromPretrained` still
        // calls the progress handler with "Downloading…" at 0% (then racing up
        // via HEAD-check fractions before the real in-memory load phase). That
        // would surface as a spurious "Downloading 0%" flash in the UI every
        // time the user switched back to a cached Qwen backend. Detect the
        // cached case at entry and pin progress to indeterminate "Loading…"
        // regardless of what the library reports.
        let alreadyDownloaded = ModelStore.isDownloaded(backend)
        setState(.loading(progress: alreadyDownloaded ? -1 : 0))

        do {
            let handler: (Double, String) -> Void = { [weak self] fraction, status in
                guard let self else { return }
                if alreadyDownloaded {
                    self.setState(.loading(progress: -1))
                } else {
                    let clamped = max(0.0, min(1.0, fraction))
                    self.setState(.loading(progress: clamped))
                }
                Log.asr.debug("Qwen load \(Int(fraction * 100))% — \(status, privacy: .public)")
            }

            let loaded = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId,
                cacheDir: cacheDir,
                offlineMode: false,
                progressHandler: handler
            )
            self.model = loaded
            setState(.ready)
            Log.asr.info("Qwen3-ASR loaded: \(self.modelId, privacy: .public)")
        } catch {
            setState(.failed(error))
            Log.asr.error("Qwen prepare failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func transcribe(_ buffer: AudioBuffer,
                            language: Language,
                            context: String?) async throws -> String {
        let samples = buffer.samples
        let sr = Int(buffer.sampleRate)
        let lang = language.qwenName
        // `context` lands in Qwen3-ASR's `<|im_start|>system\n{context}<|im_end|>`
        // slot, so the model treats it as task instructions for this utterance.
        let ctx = context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Guard against buffers too short for Whisper's mel-spectrogram
        // preprocessing. `WhisperFeatureExtractor.extractFeatures` assumes
        // `audio.count >= 1` and indexes `audio[audio.count - 1]` unconditionally
        // in its reflect-padding loop — an empty or near-empty buffer crashes
        // the process (Swift runtime: Index out of range).
        // `nFFT` is 400 samples (25ms @ 16kHz); require at least one full window.
        let minSamples = 400
        guard samples.count >= minSamples else {
            Log.asr.warning("Qwen transcribe skipped: \(samples.count, privacy: .public) samples < \(minSamples, privacy: .public) required")
            return ""
        }

        // `transcribe` is synchronous/blocking. Run on a detached task so we don't hog
        // the caller. Model is non-Sendable but we access it through `self`
        // (@unchecked Sendable) and serialize with `transcribeLock`.
        let text: String = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> String in
            guard let self else {
                throw NSError(domain: "VoiceTyping.ASR", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Recognizer was deallocated"])
            }
            return try self.transcribeLock.withLock { () throws -> String in
                guard let model = self.model else {
                    throw NSError(domain: "VoiceTyping.ASR", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Recognizer not prepared"])
                }
                return model.transcribe(
                    audio: samples,
                    sampleRate: sr,
                    language: lang,
                    maxTokens: 448,
                    context: ctx
                )
            }
        }.value

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.asr.info("Qwen transcribed \(buffer.duration, format: .fixed(precision: 2))s → \(cleaned.count, privacy: .public) chars")
        return cleaned
    }

    public func cancel() {
        // No cancel hook on Qwen3ASRModel; transcribe is synchronous, so the Task above
        // runs to completion. Nothing actionable here.
    }

    /// Free model weights. Called when the backend is being swapped out.
    public func unload() {
        transcribeLock.withLock {
            model?.unload()
            model = nil
        }
        setState(.unloaded)
    }

    private func setState(_ newState: RecognizerState) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
        stateContinuation?.yield(newState)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Streaming transcription (v0.4.2)

public extension QwenASRRecognizer {

    /// Emit transcript progressively as VAD-bounded segments finish ASR. Each yield
    /// carries the accumulated text so far; the final yield is the complete transcript.
    /// Designed for post-record streaming — caller passes the full buffer after Fn release.
    ///
    /// Runs on a detached task so yields propagate to the consumer in real time (each
    /// segment's ASR call takes hundreds of ms). Shares the Qwen3ASRModel with the batch
    /// path; serialised via `transcribeLock` — callers must not run streaming and batch
    /// concurrently (AppDelegate's `pipelineTask` already enforces single-flight).
    func transcribeStreaming(
        _ buffer: AudioBuffer,
        language: Language,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish(throwing: NSError(
                        domain: "VoiceTyping.ASR", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Recognizer was deallocated"]))
                    return
                }
                do {
                    let box = try await Self.vadActor.get()
                    try self.runStreaming(
                        buffer: buffer,
                        language: language,
                        context: context,
                        vadBox: box,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Synchronous body of `transcribeStreaming` — acquires `transcribeLock` to serialise
    /// against batch calls, walks the audio through VAD, calls Qwen per detected segment,
    /// and yields the accumulated transcript after each segment.
    private func runStreaming(
        buffer: AudioBuffer,
        language: Language,
        context: String?,
        vadBox: SharedVADBox,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        try transcribeLock.withLock { () throws -> Void in
            guard let asr = self.model else {
                throw NSError(domain: "VoiceTyping.ASR", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Recognizer not prepared"])
            }

            let vad = vadBox.model
            let lang = language.qwenName
            let ctx = context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let samples = buffer.samples
            let chunkSize = SileroVADModel.chunkSize
            let maxSegmentDuration: Float = 10.0

            // Silero VAD holds RNN hidden state between chunks; reset at both entry and
            // exit so a previous run can't bias the state machine on the next press.
            vad.resetState()
            defer { vad.resetState() }

            let processor = StreamingVADProcessor(model: vad)
            var speechStartSample: Int?
            var accumulated = ""

            func transcribeSegment(startSample: Int, endSample: Int) {
                guard startSample < endSample else { return }
                let segAudio = Array(samples[startSample..<endSample])
                // Same minimum-FFT-window guard as the batch path: <400 samples
                // crashes WhisperFeatureExtractor's reflect padding.
                guard segAudio.count >= 400 else { return }
                let text = asr.transcribe(
                    audio: segAudio, sampleRate: 16000,
                    language: lang, maxTokens: 448, context: ctx
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if !accumulated.isEmpty { accumulated += " " }
                accumulated += trimmed
                continuation.yield(accumulated)
            }

            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()

                let end = min(offset + chunkSize, samples.count)
                let events = processor.process(samples: Array(samples[offset..<end]))

                for event in events {
                    switch event {
                    case .speechStarted(let t):
                        speechStartSample = Int(t * 16000)
                    case .speechEnded(let seg):
                        if let start = speechStartSample {
                            transcribeSegment(startSample: start,
                                              endSample: min(Int(seg.endTime * 16000), samples.count))
                            speechStartSample = nil
                        }
                    }
                }

                // Force-split if a single utterance exceeds maxSegmentDuration so we don't
                // exhaust Qwen's maxTokens budget on a runaway speech span.
                if let start = speechStartSample {
                    let now = processor.currentTime
                    let speechStart = Float(start) / 16000
                    if now - speechStart >= maxSegmentDuration {
                        let endSample = min(Int(now * 16000), samples.count)
                        transcribeSegment(startSample: start, endSample: endSample)
                        speechStartSample = Int(now * 16000)
                    }
                }

                offset = end
            }

            // Flush any trailing speech at EOF.
            let flushEvents = processor.flush()
            for event in flushEvents {
                if case .speechEnded(let seg) = event, let start = speechStartSample {
                    transcribeSegment(startSample: start,
                                      endSample: min(Int(seg.endTime * 16000), samples.count))
                    speechStartSample = nil
                }
            }

            // If VAD never fired (very short / soft audio), fall back to a single
            // transcription of the full buffer so the user still gets output.
            if accumulated.isEmpty {
                transcribeSegment(startSample: 0, endSample: samples.count)
            }

            Log.asr.info("Qwen streaming \(buffer.duration, format: .fixed(precision: 2))s → \(accumulated.count, privacy: .public) chars")
        }
    }

    // MARK: - Shared Silero VAD

    /// Silero VAD is ~2 MB and model-agnostic — keep a single instance across
    /// recognizer swaps so switching Qwen 0.6B ↔ 1.7B doesn't re-download it.
    static let vadActor = VADActor()

    /// Serialises concurrent first-time loads and caches the result. Returns a
    /// `SharedVADBox` because `SileroVADModel` itself isn't Sendable — callers
    /// unwrap `.model` inside their own serialised region (e.g. under `transcribeLock`).
    actor VADActor {
        private var box: SharedVADBox?
        private var inflight: Task<SharedVADBox, Error>?

        func get() async throws -> SharedVADBox {
            if let box { return box }
            if let inflight { return try await inflight.value }

            let task = Task {
                let model = try await SileroVADModel.fromPretrained()
                return SharedVADBox(model)
            }
            inflight = task
            do {
                let loaded = try await task.value
                box = loaded
                inflight = nil
                return loaded
            } catch {
                inflight = nil
                throw error
            }
        }
    }
}

/// Sendable conduit for `SileroVADModel`, which upstream hasn't marked Sendable.
/// Access to `.model` must happen inside a serialised region (we use `transcribeLock`).
final class SharedVADBox: @unchecked Sendable {
    let model: SileroVADModel
    init(_ model: SileroVADModel) { self.model = model }
}
