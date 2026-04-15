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
    func transcribe(_ buffer: AudioBuffer, language: Language) async throws -> String
    func cancel()
}
