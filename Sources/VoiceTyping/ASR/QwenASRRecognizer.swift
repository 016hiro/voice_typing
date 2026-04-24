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
        // v0.5.1 性能基线 follow-up: when our strict `isComplete` check passes,
        // pass `offlineMode: true` to upstream so it skips the HuggingFace HEAD
        // sweep (`HuggingFaceDownloader.downloadWeights` early-returns on
        // `offlineMode && weightsExist`). Real measurement showed dl_init
        // dominates cached prepare at 3-4 s while the actual mmap-based weight
        // load is <20 ms. Falls back to network mode for first-time downloads
        // or when `repairIfIncomplete` (in `activateBackend`) just cleared a
        // partial state.
        let canSkipHEAD = ModelStore.isComplete(backend)
        setState(.loading(progress: alreadyDownloaded ? -1 : 0))

        // v0.5.1 性能基线 A: per-stage wall-clock from upstream progress
        // callbacks. Buckets correspond to `Qwen3ASRModel.fromPretrained`
        // status string transitions. NOTE: text-decoder weights and
        // `MetalBudget.pinMemory` share the final bucket because upstream
        // emits no callback between them — see todo/v0.5.1.md "性能基线 B".
        let prepStart = Date()
        let timing = LoadStageTimer(initialStage: "init")

        do {
            let handler: (Double, String) -> Void = { [weak self] fraction, status in
                guard let self else { return }
                timing.mark(stage: status)
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
                offlineMode: canSkipHEAD,
                progressHandler: handler
            )
            self.model = loaded
            timing.mark(stage: "loaded")
            let loadMs = Int(Date().timeIntervalSince(prepStart) * 1000)

            // First-inference warmup. Metal kernels JIT on first dispatch, so
            // the first user-visible transcribe used to be 5-10× slower than
            // steady state. Burning 1 s of silence here moves that cost into
            // prepare. Result is discarded; `transcribeSegmentSync` doesn't
            // apply HallucinationFilter, so any training-tail output is
            // silently dropped without polluting logs.
            let warmupMs: Int = await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return 0 }
                let start = Date()
                let silence = [Float](repeating: 0, count: 16000)
                _ = self.transcribeSegmentSync(samples: silence, language: "en", context: nil)
                return Int(Date().timeIntervalSince(start) * 1000)
            }.value

            let totalMs = Int(Date().timeIntervalSince(prepStart) * 1000)
            Log.app.info("Qwen prepare timing: backend=\(self.backend.rawValue, privacy: .public) cached=\(alreadyDownloaded ? "yes" : "no", privacy: .public) offline=\(canSkipHEAD ? "yes" : "no", privacy: .public) total=\(totalMs, privacy: .public)ms load=\(loadMs, privacy: .public)ms warmup=\(warmupMs, privacy: .public)ms stages=[\(timing.summary, privacy: .public)]")

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

    /// Synchronous segment transcription used by `LiveTranscriber`. Caller is
    /// responsible for being off the main thread. Acquires `transcribeLock`
    /// per call so live segments interleave safely with the (rare) batch
    /// transcribe — no lock held across awaits.
    ///
    /// Returns `""` if the model isn't loaded or the segment is shorter than
    /// one FFT window (400 samples); both conditions are silently dropped
    /// rather than throwing because mid-stream errors would tear down the
    /// live session for what's typically a transient or trivial cause.
    func transcribeSegmentSync(samples: [Float], language: String, context: String?) -> String {
        guard samples.count >= 400 else { return "" }
        return transcribeLock.withLock { () -> String in
            guard let model = self.model else { return "" }
            return model.transcribe(
                audio: samples, sampleRate: 16000,
                language: language, maxTokens: 448, context: context
            )
        }
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

/// v0.5.1 性能基线 A: tracks elapsed wall-clock per upstream-emitted load
/// stage. The handler called by `Qwen3ASRModel.fromPretrained` may fire
/// many times per stage (download progress fractions); we only record a
/// new bucket when the status string actually changes, so each entry is
/// "time spent in stage X before transitioning to stage Y".
///
/// Class (not struct) so the closure passed to `fromPretrained` can mutate
/// shared state without `inout` ceremony. `@unchecked Sendable` because
/// `NSLock` guards all mutation; the handler is called sequentially by
/// upstream, but better safe than sorry.
private final class LoadStageTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: Date
    private var lastStage: String
    private var stages: [(String, Int)] = []

    init(initialStage: String) {
        self.lastTime = Date()
        self.lastStage = initialStage
    }

    func mark(stage newStage: String) {
        lock.lock(); defer { lock.unlock() }
        guard newStage != lastStage else { return }
        let now = Date()
        let ms = Int(now.timeIntervalSince(lastTime) * 1000)
        stages.append((shortKey(lastStage), ms))
        lastTime = now
        lastStage = newStage
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return stages.map { "\($0.0)=\($0.1)ms" }.joined(separator: " ")
    }

    /// Compact key for log readability. Upstream status strings are verbose
    /// ("Loading audio encoder weights...") — shorten to one token each.
    /// Unknown strings fall through with whitespace stripped so future
    /// upstream additions still appear (just less pretty).
    private func shortKey(_ status: String) -> String {
        switch status {
        case "init":                              return "init"
        case "Downloading model...":              return "dl_init"
        case "Downloading weights...":            return "download"
        case "Loading tokenizer...":              return "tokenizer"
        case "Loading audio encoder weights...": return "audio_w"
        case "Loading text decoder weights...": return "text_w_pin"
        case "Ready":                             return "ready"
        case "loaded":                            return "loaded"
        default:
            return status
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: ".", with: "")
                .lowercased()
        }
    }
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

        /// v0.5.0 shipping defaults: `minSpeech 0.3s, minSilence 0.7s, no padding,
        /// force-split 25s`.
        ///
        /// History:
        /// - v0.4.5 picked `(0.3, 0.7, 0)` over Silero's `(0.25, 0.10)` after the
        ///   benchmark showed ~99 % similarity to batch + 17 % lower latency + 3.3 → 1.4
        ///   partials per fixture, and recovered a leading word `0.5s` was dropping.
        /// - v0.5.0 raised `maxSegmentDuration` 10 → 25. Qwen3-ASR's actual hard
        ///   cap is 1200 s (`AudioPreprocessing.swift:304`); the practical cap is
        ///   `maxTokens=448` which 25 s of speech (~120-150 output tokens) sits
        ///   well inside. A user talking continuously for 15-20 s used to take a
        ///   force-split mid-word at 10 s; raising the threshold avoids that for
        ///   nearly all natural utterances. Validated by `make benchmark-vad`.
        public static let production = StreamingTuning(
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.7,
            paddingSeconds: 0,
            maxSegmentDuration: 25.0
        )

        internal func buildVADConfig() -> VADConfig {
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
        try transcribeLock.withLock { () throws in
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
