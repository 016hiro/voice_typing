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

    /// v0.7.0: streaming variant — yields *delta* chunks (not cumulative) as
    /// the LLM produces them. Used by the streaming inject path; the batch
    /// `refine(...)` above stays for raw-first / Notion-deny / pre-streaming
    /// callers (see ADR 0001).
    ///
    /// On error the stream finishes with that error — callers handle
    /// fail-open (returning input text on failure) themselves. This is
    /// intentionally different from `refine`'s baked-in fail-open: a
    /// half-streamed inject can't be transparently swapped for the input
    /// string, so the caller has to decide what to do with partial output.
    ///
    /// A default implementation in the extension below derives this from
    /// `refine` by emitting the full result as a single chunk — lets impls
    /// satisfy the protocol unchanged. Cloud / local override with true
    /// incremental yield in #R3 / #R4.
    func refineStream(_ text: String,
                      language: Language,
                      mode: RefineMode,
                      glossary: String?,
                      profileSnippet: String?) -> AsyncThrowingStream<String, Error>

    /// Sends a tiny test request to confirm the impl is wired up correctly
    /// (credentials valid, endpoint reachable, weights loaded, etc.). Used by
    /// the Settings UI's "Test connection" button. Not on the hot path.
    func test() async -> LLMRefiningTestResult
}

extension LLMRefining {

    /// Default `refineStream` — wraps the batch `refine` as a single yield.
    /// Inherited by impls that haven't been migrated to true streaming;
    /// preserves end-to-end behavior so callers can adopt the streaming
    /// API ahead of impl-level streaming work.
    func refineStream(_ text: String,
                      language: Language,
                      mode: RefineMode,
                      glossary: String?,
                      profileSnippet: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let result = await self.refine(text,
                                               language: language,
                                               mode: mode,
                                               glossary: glossary,
                                               profileSnippet: profileSnippet)
                continuation.yield(result)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum LLMRefiningTestResult: Sendable {
    case ok(sampleReply: String)
    case failed(String)
}

/// Shared text-handling helpers used by both `CloudLLMRefiner` and
/// `LocalMLXRefiner`. Pure functions — no I/O, no model state.
enum LLMRefiningHelpers {

    /// Composes the final system prompt by stacking parts from most general
    /// to most specific: `mode baseline → per-app profile → custom glossary`.
    /// Empty/whitespace parts are skipped.
    static func compose(systemPrompt: String,
                        profileSnippet: String?,
                        glossary: String?) -> String {
        var parts: [String] = [systemPrompt]
        if let snippet = profileSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty {
            parts.append(snippet)
        }
        if let glossary, !glossary.isEmpty {
            parts.append(glossary)
        }
        return parts.joined(separator: "\n\n")
    }

    /// LLMs sometimes wrap their reply in code fences or quote pairs even
    /// when explicitly told not to. Strip a single outer layer of either.
    /// Used by both refiner impls to keep output ready to paste.
    static func stripQuotesAndCode(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
        }
        for pair in [("\"", "\""), ("\u{201C}", "\u{201D}"), ("「", "」"), ("『", "』")] {
            if t.hasPrefix(pair.0) && t.hasSuffix(pair.1) && t.count > 1 {
                t = String(t.dropFirst().dropLast())
                break
            }
        }
        return t
    }

    /// Qwen3 templates have a known bug where `enable_thinking=False` still
    /// emits an empty `<think>\n\n</think>` block at the start of the reply.
    /// Strip it so downstream code (paste / replace) doesn't treat it as
    /// content. Safe no-op for non-Qwen3 outputs.
    static func stripEmptyThinkBlock(_ s: String) -> String {
        let pattern = #"^<think>\s*</think>\s*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
