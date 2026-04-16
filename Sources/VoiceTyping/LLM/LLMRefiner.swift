import Foundation

/// Stateless OpenAI-compatible chat client; safe to share across actors.
final class LLMRefiner: Sendable {

    enum TestResult {
        case ok(sampleReply: String)
        case failed(String)
    }

    /// Refines `text` using the given `mode`. Optional `glossary` is a pre-formatted
    /// Markdown block from `GlossaryBuilder.buildLLMGlossary` that gets appended
    /// after the mode's system prompt.
    ///
    /// On any failure (network, timeout, auth, decode), returns the original input
    /// unchanged — matching v0.1+ fail-open behavior.
    func refine(_ text: String,
                language: Language,
                mode: RefineMode,
                glossary: String? = nil,
                config: LLMConfig) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let systemPrompt = mode.systemPrompt else { return text }    // .off
        guard config.hasCredentials else { return text }

        let finalSystem = Self.compose(systemPrompt: systemPrompt, glossary: glossary)

        do {
            let reply = try await chat(
                system: finalSystem,
                user: trimmed,
                config: config
            )
            let cleaned = Self.stripQuotesAndCode(reply).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.llm.info("Refined (\(mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(cleaned.count, privacy: .public) chars")
            return cleaned.isEmpty ? text : cleaned
        } catch {
            Log.llm.warning("Refine failed: \(String(describing: error), privacy: .public)")
            return text
        }
    }

    private static func compose(systemPrompt: String, glossary: String?) -> String {
        guard let glossary, !glossary.isEmpty else { return systemPrompt }
        return systemPrompt + "\n\n" + glossary
    }

    /// Sends a tiny test message to confirm credentials work.
    func test(config: LLMConfig) async -> TestResult {
        guard config.hasCredentials else { return .failed("Configuration incomplete") }
        do {
            let reply = try await chat(
                system: "You are a test responder. Reply with 'ok'.",
                user: "ping",
                config: config
            )
            return .ok(sampleReply: reply)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - HTTP

    private func chat(system: String, user: String, config: LLMConfig) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw NSError(domain: "VoiceTyping.LLM", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
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
            throw NSError(domain: "VoiceTyping.LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr.prefix(200))"])
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "VoiceTyping.LLM", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape"])
        }
        return content
    }

    private static func stripQuotesAndCode(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
        }
        // Strip surrounding straight / curly quotes
        for pair in [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』")] {
            if t.hasPrefix(pair.0) && t.hasSuffix(pair.1) && t.count > 1 {
                t = String(t.dropFirst().dropLast())
                break
            }
        }
        return t
    }
}
