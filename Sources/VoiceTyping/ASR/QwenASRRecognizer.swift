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
            Log.dev(Log.asr, "Qwen3-ASR loaded: \(self.modelId)")
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

    /// Knobs that influence VAD-driven streaming. Default matches v0.4.2 behavior
    /// so existing callers see no change. Used by the v0.4.5 benchmark + future
    /// Phase 1 tuning work to compare segmentation strategies.
    struct StreamingTuning: Sendable {
        /// Override `VADConfig.minSpeechDuration`. `nil` = upstream Silero default (0.25s).
        public let minSpeechDuration: Float?
        /// Override `VADConfig.minSilenceDuration`. `nil` = upstream Silero default (0.10s).
        public let minSilenceDuration: Float?
        /// Pad each transcribed segment by this many seconds on both ends (clamped
        /// to buffer bounds). 0 = no padding (v0.4.2 behavior). Padding is applied
        /// to force-split and fallback paths too — minor overlap between adjacent
        /// segments is harmless.
        public let paddingSeconds: Float
        /// Force-split threshold when a single speech span exceeds this duration.
        public let maxSegmentDuration: Float

        public init(
            minSpeechDuration: Float? = nil,
            minSilenceDuration: Float? = nil,
            paddingSeconds: Float = 0,
            maxSegmentDuration: Float = 10.0
        ) {
            self.minSpeechDuration = minSpeechDuration
            self.minSilenceDuration = minSilenceDuration
            self.paddingSeconds = paddingSeconds
            self.maxSegmentDuration = maxSegmentDuration
        }

        /// Upstream Silero defaults — `(0.25s, 0.10s)`. Kept as the no-override
        /// baseline so the benchmark and any opt-out caller can compare.
        public static let `default` = StreamingTuning()

        /// v0.4.5 shipping defaults: `minSpeech 0.3s, minSilence 0.7s, no padding`.
        /// Validated by `make benchmark-vad` — same average similarity to batch
        /// (~99 %), 17 % lower latency, segment count cut from 3.3 to 1.4 per
        /// fixture, and recovers the leading word that `0.5s` was dropping.
        /// Used by `AppDelegate.runASR`'s streaming path.
        public static let production = StreamingTuning(
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.7,
            paddingSeconds: 0,
            maxSegmentDuration: 10.0
        )

        fileprivate func buildVADConfig() -> VADConfig {
            var cfg = VADConfig.sileroDefault
            if let m = minSpeechDuration { cfg.minSpeechDuration = m }
            if let m = minSilenceDuration { cfg.minSilenceDuration = m }
            return cfg
        }
    }

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
        context: String?,
        tuning: StreamingTuning = .default
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
                        tuning: tuning,
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
        tuning: StreamingTuning,
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
            let maxSegmentDuration = tuning.maxSegmentDuration
            let padSamples = max(0, Int(tuning.paddingSeconds * 16000))

            // Silero VAD holds RNN hidden state between chunks; reset at both entry and
            // exit so a previous run can't bias the state machine on the next press.
            vad.resetState()
            defer { vad.resetState() }

            let processor = StreamingVADProcessor(model: vad, config: tuning.buildVADConfig())
            var speechStartSample: Int?
            var accumulated = ""

            func transcribeSegment(startSample: Int, endSample: Int) {
                // Pad on both ends to give the ASR model extra acoustic context —
                // VAD boundaries aren't exactly at word edges, and Qwen/Whisper
                // hallucinate less when the segment has a small buffer of silence/
                // speech around the detected span.
                let paddedStart = max(0, startSample - padSamples)
                let paddedEnd = min(endSample + padSamples, samples.count)
                guard paddedStart < paddedEnd else { return }
                let segAudio = Array(samples[paddedStart..<paddedEnd])
                // Same minimum-FFT-window guard as the batch path: <400 samples
                // crashes WhisperFeatureExtractor's reflect padding.
                guard segAudio.count >= 400 else { return }
                let text = asr.transcribe(
                    audio: segAudio, sampleRate: 16000,
                    language: lang, maxTokens: 448, context: ctx
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // Drop training-data tails (`谢谢观看`, `Thank you.`) and
                // segments that echo the bias `context` we just passed (the
                // `热词：…` regurgitation observed on noisy short input).
                // Without this filter, those segments leak straight into the
                // injected text and the user has to delete them.
                if HallucinationFilter.isLikelyHallucination(segment: trimmed, context: ctx) {
                    Log.dev(Log.asr, "Hallucination filtered: \(trimmed)")
                    return
                }
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

    /// Silero VAD is ~1.2 MB and model-agnostic — keep a single instance across
    /// recognizer swaps so switching Qwen 0.6B ↔ 1.7B doesn't re-download it.
    static let vadActor = VADActor()

    /// v0.4.4: weights are bundled at `<app>/Contents/Resources/SileroVAD/`
    /// (staged by `make build`), so the VAD loads offline. Returns nil when
    /// the bundle copy isn't present — e.g. running via `swift run` / `swift test`
    /// without `make build`, in which case we fall back to HuggingFace (the
    /// upstream default cache at `~/Library/Caches/qwen3-speech/...`).
    fileprivate static func bundledVADCacheDir() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("SileroVAD", isDirectory: true)
        let weights = candidate.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weights.path) else { return nil }
        return candidate
    }

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
                let model: SileroVADModel
                if let bundled = QwenASRRecognizer.bundledVADCacheDir() {
                    Log.dev(Log.asr, "Loading Silero VAD from app bundle: \(bundled.path)")
                    model = try await SileroVADModel.fromPretrained(
                        cacheDir: bundled, offlineMode: true
                    )
                } else {
                    Log.dev(Log.asr, "Silero VAD not bundled — falling back to HuggingFace cache")
                    model = try await SileroVADModel.fromPretrained()
                }
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
