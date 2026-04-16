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
        self.cacheDir = cacheDir

        let (stream, cont) = AsyncStream<RecognizerState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.stateStream = stream
        self.stateContinuation = cont
    }

    deinit {
        stateContinuation?.finish()
    }

    public func prepare() async throws {
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

    public func transcribe(_ buffer: AudioBuffer, language: Language) async throws -> String {
        let samples = buffer.samples
        let sr = Int(buffer.sampleRate)
        let lang = language.qwenName

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
                    context: nil
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
