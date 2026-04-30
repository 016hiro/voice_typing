import Foundation

/// HTTP-backed `LLMRefining` — speaks the OpenAI-compatible Chat Completions
/// API. Stateless beyond its injected `LLMConfig`; safe to share across actors
/// and cheap enough to recreate per-call (AppDelegate uses a computed property
/// that snapshots `state.llmConfig` on each access).
final class CloudLLMRefiner: LLMRefining {

    private let config: LLMConfig

    init(config: LLMConfig) {
        self.config = config
    }

    /// Refines `text` using the given `mode`. Optional `glossary` is a pre-formatted
    /// Markdown block from `GlossaryBuilder.buildLLMGlossary`; optional
    /// `profileSnippet` is a per-app override pulled from `ContextProfileStore`.
    /// Both, when present, are appended to the mode's system prompt in the order
    /// `baseline → profile → glossary` (most general to most specific).
    ///
    /// On any failure (network, timeout, auth, decode), returns the original input
    /// unchanged — matching v0.1+ fail-open behavior.
    func refine(_ text: String,
                language: Language,
                mode: RefineMode,
                glossary: String?,
                profileSnippet: String?) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let systemPrompt = mode.systemPrompt else { return text }    // .off
        guard config.hasCredentials else { return text }

        let finalSystem = LLMRefiningHelpers.compose(
            systemPrompt: systemPrompt,
            profileSnippet: profileSnippet,
            glossary: glossary
        )

        do {
            let t0 = Date()
            let reply = try await chat(
                system: finalSystem,
                user: trimmed
            )
            let httpMs = Int(Date().timeIntervalSince(t0) * 1000)
            let cleaned = LLMRefiningHelpers.stripQuotesAndCode(reply)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // .notice so `log stream` (no `--level info` needed) surfaces
            // refine latency by default. Mirrors LocalMLXRefiner's format
            // for grep-friendliness; cloud has no separate load phase so
            // http_ms is the whole roundtrip.
            Log.llm.notice("CloudRefined (\(mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(cleaned.count, privacy: .public) chars in http_ms=\(httpMs, privacy: .public)")
            return cleaned.isEmpty ? text : cleaned
        } catch {
            Log.llm.warning("Cloud refine failed: \(String(describing: error), privacy: .public)")
            return text
        }
    }

    /// Sends a tiny test message to confirm credentials work.
    func test() async -> LLMRefiningTestResult {
        guard config.hasCredentials else { return .failed("Configuration incomplete") }
        do {
            let reply = try await chat(
                system: "You are a test responder. Reply with 'ok'.",
                user: "ping"
            )
            return .ok(sampleReply: reply)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - HTTP

    private func chat(system: String, user: String) async throws -> String {
        // Literal pass-through: whatever the user typed in the URL field IS the
        // POST target. No suffix-appending, no auto-stripping. Only defense is
        // trimming whitespace/newlines — pasted keys / URLs often carry a `\n`,
        // which URLSession rejects as an invalid header or URL.
        let urlString = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model  = config.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: urlString) else {
            throw NSError(domain: "VoiceTyping.LLM", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // OpenRouter recommends (but doesn't require) these for analytics /
        // abuse classification. Supplying them puts our traffic into our own
        // app's bucket rather than "unattributed".
        req.setValue("https://github.com/016hiro/voice_typing", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("VoiceTyping", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout + 2
        let session = URLSession(configuration: sessionConfig)

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Log.llm.error("LLM HTTP \(http.statusCode, privacy: .public) body=\(bodyStr, privacy: .public)")
            throw NSError(domain: "VoiceTyping.LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr.prefix(300))"])
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Log.llm.error("LLM non-JSON response: \(bodyStr, privacy: .public)")
            throw NSError(domain: "VoiceTyping.LLM", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Non-JSON response: \(bodyStr.prefix(200))"])
        }

        // OpenRouter sometimes returns HTTP 200 with `{ "error": { ... } }` when
        // the upstream provider rejects the request (invalid model id, upstream
        // rate limit, etc.). Surface that instead of the generic shape error.
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? String(describing: err)
            Log.llm.error("LLM error body: \(msg, privacy: .public)")
            throw NSError(domain: "VoiceTyping.LLM", code: 502,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            Log.llm.error("LLM unexpected shape: \(bodyStr, privacy: .public)")
            throw NSError(domain: "VoiceTyping.LLM", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape: \(bodyStr.prefix(200))"])
        }
        return content
    }
}
