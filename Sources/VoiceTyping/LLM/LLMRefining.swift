import Foundation

/// Common interface for LLM-based transcript refinement.
///
/// Two implementations live (will live) under this protocol:
/// - `CloudLLMRefiner` — HTTP / OpenAI-compatible chat endpoint (current default)
/// - `LocalMLXRefiner` — on-device MLX inference (v0.6.3 #R6, not yet implemented)
///
/// AppDelegate holds `any LLMRefining` so the active backend can be swapped
/// at runtime via Settings without touching call sites.
///
/// Per-impl config (URL/key/model for cloud; weights path / load state for
/// local) is injected at init — refine/test methods stay impl-agnostic.
protocol LLMRefining: Sendable {

    /// Refines `text` per `mode`. `glossary` and `profileSnippet`, when present,
    /// are appended to `mode`'s system prompt as additional context. On any
    /// failure (network, decode, empty creds, model error) returns `text`
    /// unchanged — fail-open behavior matching v0.1+.
    func refine(_ text: String,
                language: Language,
                mode: RefineMode,
                glossary: String?,
                profileSnippet: String?) async -> String

    /// Sends a tiny test request to confirm the impl is wired up correctly
    /// (credentials valid, endpoint reachable, weights loaded, etc.). Used by
    /// the Settings UI's "Test connection" button. Not on the hot path.
    func test() async -> LLMRefiningTestResult
}

enum LLMRefiningTestResult: Sendable {
    case ok(sampleReply: String)
    case failed(String)
}
