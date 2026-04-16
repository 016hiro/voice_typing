import Foundation
import WhisperKit

public final class WhisperKitRecognizer: SpeechRecognizer, @unchecked Sendable {

    public static let defaultModel = "openai_whisper-large-v3"
    public static let defaultRepo  = "argmaxinc/whisperkit-coreml"

    private let modelName: String
    private let modelRepo: String
    private let downloadBase: URL

    private var pipeline: WhisperKit?
    private var currentTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var _state: RecognizerState = .unloaded
    public var state: RecognizerState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private var stateContinuation: AsyncStream<RecognizerState>.Continuation?
    public let stateStream: AsyncStream<RecognizerState>

    public init(model: String = WhisperKitRecognizer.defaultModel,
                repo: String = WhisperKitRecognizer.defaultRepo,
                downloadBase: URL) {
        self.modelName = model
        self.modelRepo = repo
        self.downloadBase = downloadBase

        let (stream, cont) = AsyncStream<RecognizerState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.stateStream = stream
        self.stateContinuation = cont
    }

    deinit {
        stateContinuation?.finish()
    }

    public func prepare() async throws {
        setState(.loading(progress: -1))   // indeterminate — WhisperKit doesn't expose granular progress

        do {
            let config = WhisperKitConfig(
                model: modelName,
                downloadBase: downloadBase,
                modelRepo: modelRepo,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            let pipe = try await WhisperKit(config)
            self.pipeline = pipe
            setState(.ready)
            Log.asr.info("WhisperKit loaded: \(self.modelName, privacy: .public)")
        } catch {
            setState(.failed(error))
            Log.asr.error("WhisperKit prepare failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func transcribe(_ buffer: AudioBuffer,
                            language: Language,
                            context: String?) async throws -> String {
        guard let pipe = pipeline else {
            throw NSError(domain: "VoiceTyping.ASR", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recognizer not prepared"])
        }

        // WhisperKit's audio pipeline also assumes a non-trivial sample count.
        // Match the Qwen guard to avoid any chance of an empty-buffer crash
        // inside the mel extractor.
        let minSamples = 400
        guard buffer.samples.count >= minSamples else {
            Log.asr.warning("Whisper transcribe skipped: \(buffer.samples.count, privacy: .public) samples < \(minSamples, privacy: .public) required")
            return ""
        }

        // Tokenize the dictionary bias string via WhisperKit's own tokenizer.
        // WhisperKit will clip this at 224 tokens internally (sampleLength) —
        // GlossaryBuilder already keeps us well under that.
        let biasPrompt = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTokens: [Int]?
        if let biasPrompt, !biasPrompt.isEmpty, let tok = pipe.tokenizer {
            let ids = tok.encode(text: " " + biasPrompt)
                .filter { $0 < tok.specialTokens.specialTokenBegin }
            promptTokens = ids.isEmpty ? nil : ids
        } else {
            promptTokens = nil
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.whisperCode,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            suppressBlank: true
        )

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: buffer.samples,
            decodeOptions: options
        )

        let text = results.map { $0.text }.joined(separator: " ")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.asr.info("Transcribed \(buffer.duration, format: .fixed(precision: 2))s → \(cleaned.count, privacy: .public) chars")
        return cleaned
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func setState(_ newState: RecognizerState) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
        stateContinuation?.yield(newState)
    }
}
