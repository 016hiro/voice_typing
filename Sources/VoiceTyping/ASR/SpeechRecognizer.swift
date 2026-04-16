import Foundation

public enum RecognizerState: Sendable {
    case unloaded
    case loading(progress: Double)   // progress in 0...1; use negative for indeterminate
    case ready
    case failed(Error)
}

public protocol SpeechRecognizer: AnyObject, Sendable {
    /// Long-lived stream of model state changes. Subscribers should not expect replay;
    /// the current state can be queried synchronously via `state`.
    var stateStream: AsyncStream<RecognizerState> { get }
    var state: RecognizerState { get }

    func prepare() async throws

    /// Transcribe the given buffer. `context` is an optional prompt-bias string
    /// (domain glossary / canonical term list); backends that don't support it
    /// should ignore it. Callers pass `nil` when the user's dictionary is empty.
    func transcribe(_ buffer: AudioBuffer,
                    language: Language,
                    context: String?) async throws -> String
    func cancel()
}

public extension SpeechRecognizer {
    /// Convenience overload for call sites that don't need prompt biasing.
    func transcribe(_ buffer: AudioBuffer, language: Language) async throws -> String {
        try await transcribe(buffer, language: language, context: nil)
    }
}
