import Foundation
import os
import Qwen3ASR

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

        setState(.loading(progress: 0))

        do {
            let handler: (Double, String) -> Void = { [weak self] fraction, status in
                guard let self else { return }
                let clamped = max(0.0, min(1.0, fraction))
                self.setState(.loading(progress: clamped))
                Log.asr.debug("Qwen download \(Int(clamped * 100))% — \(status, privacy: .public)")
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
