import Foundation

/// HTTP-backed `LLMRefining` — speaks the OpenAI-compatible Chat Completions
/// API in **streaming mode** (SSE). Stateless beyond its injected `LLMConfig`;
/// safe to share across actors and cheap enough to recreate per-call
/// (AppDelegate uses a computed property that snapshots `state.llmConfig` on
/// each access).
///
/// **v0.6.3 — why streaming**: dogfood discovered that non-streaming requests
/// to OpenRouter (and any reasoning-token model anywhere) were timing out
/// at 100% rate even though the in-app "Test" button passed. Two reasons:
///   1. OpenRouter sends `: OPENROUTER PROCESSING` SSE comments as keep-
///      alives; non-streaming has no heartbeat so any client/edge idle
///      timer fires mid-completion.
///   2. Reasoning models (`o1`, `o3`, `r1`, `:thinking`, `gpt-5`) buffer
///      the entire chain-of-thought + visible response before returning a
///      single non-streaming reply, routinely 30-60 s.
/// Streaming defeats both: heartbeats keep the socket alive, and partial
/// `delta.content` chunks return the visible reply progressively.
final class CloudLLMRefiner: LLMRefining {

    private let config: LLMConfig

    init(config: LLMConfig) {
        self.config = config
    }

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
            Log.llm.notice("CloudRefined (\(mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(cleaned.count, privacy: .public) chars in http_ms=\(httpMs, privacy: .public)")
            return cleaned.isEmpty ? text : cleaned
        } catch {
            Log.llm.warning("Cloud refine failed: \(String(describing: error), privacy: .public)")
            return text
        }
    }

    /// v0.6.3: test now sends a representative refine payload (real mode
    /// system prompt + a 60-char user message) instead of the old "ping →
    /// ok" trivial case. The trivial case fit two tokens in any timeout
    /// window and gave false-positive OK while the real refine timed out.
    func test() async -> LLMRefiningTestResult {
        guard config.hasCredentials else { return .failed("Configuration incomplete") }
        let system = RefineMode.aggressive.systemPrompt ?? "Improve the input text."
        let user = "this is a test sentence with some um typos to fix and—small punctuation issues"
        do {
            let reply = try await chat(system: system, user: user)
            return .ok(sampleReply: reply)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - HTTP (streaming)

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

        // Reasoning models hold the entire chain-of-thought before the first
        // visible token. Even with streaming, more headroom is prudent.
        let effectiveTimeout = max(config.timeout, Self.recommendedTimeout(for: model))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = effectiveTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // SSE expects this; some upstreams serve plain JSON if Accept is */*.
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // OpenRouter recommends (but doesn't require) these for analytics /
        // abuse classification. Supplying them puts our traffic into our own
        // app's bucket rather than "unattributed".
        req.setValue("https://github.com/016hiro/voice_typing", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("VoiceTyping", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "stream": true,
            // OpenAI deprecated `max_tokens` in favor of `max_completion_tokens`;
            // OpenRouter accepts either. 1024 is generous for refine outputs
            // (typical < 200 tokens) and caps tail latency on reasoning models
            // that would otherwise spend the whole budget on chain-of-thought.
            "max_completion_tokens": 1024,
            // Suppress reasoning tokens in the response. Without this, models
            // like deepseek-r1 / o1 / *:thinking emit `message.reasoning` (or
            // mid-stream `delta.reasoning`) which we'd discard anyway — wasting
            // both tokens and wall-clock.
            "reasoning": ["exclude": true],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = effectiveTimeout
        // Total request budget — generous because streaming with heartbeats
        // means the request-timeout above governs idle, not total. Some
        // providers (Anthropic with reasoning, GPT-5) legitimately stream
        // for 60-90 s end-to-end.
        sessionConfig.timeoutIntervalForResource = effectiveTimeout * 3
        let session = URLSession(configuration: sessionConfig)

        let (bytes, response) = try await session.bytes(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Drain the body for the error message. Cap at 4 KB — the API
            // sometimes streams a long error trace and we only need the first
            // line for the user-facing message.
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            let bodyStr = String(data: body, encoding: .utf8) ?? ""
            Log.llm.error("LLM HTTP \(http.statusCode, privacy: .public) body=\(bodyStr, privacy: .public)")
            throw NSError(domain: "VoiceTyping.LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.errorLabel(forStatus: http.statusCode, body: bodyStr)])
        }

        // SSE consumer loop. `bytes.lines` yields complete lines without the
        // trailing newline; SSE comments (`: OPENROUTER PROCESSING`) keep the
        // socket warm and are skipped. `data: [DONE]` terminates the stream.
        var accumulated = ""
        var sawAnyData = false
        for try await line in bytes.lines {
            switch SSEParser.parse(line: line) {
            case .skip:
                continue
            case .content(let chunk):
                accumulated += chunk
                sawAnyData = true
            case .error(let msg):
                Log.llm.error("LLM streamed error: \(msg, privacy: .public)")
                throw NSError(domain: "VoiceTyping.LLM", code: 502,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            case .done:
                return accumulated
            }
        }

        // Stream ended without an explicit `[DONE]`. If we got *some* content,
        // return it (some providers omit the terminator); otherwise treat as
        // a truncation error so the caller doesn't paste an empty refine.
        if sawAnyData {
            return accumulated
        }
        throw NSError(domain: "VoiceTyping.LLM", code: 500,
                      userInfo: [NSLocalizedDescriptionKey: "Stream closed without any content"])
    }

    // MARK: - Helpers

    /// Heuristic: bump timeout for model ids that include reasoning markers.
    /// Substring match — model ids on OpenRouter look like `openai/o1-mini`,
    /// `deepseek/deepseek-r1`, `anthropic/claude-3.7-sonnet:thinking`, etc.
    static func recommendedTimeout(for model: String) -> TimeInterval {
        let lower = model.lowercased()
        let reasoningMarkers = ["/o1", "/o3", "deepseek-r1", ":thinking", "gpt-5", "qwq"]
        if reasoningMarkers.contains(where: { lower.contains($0) }) {
            return 90
        }
        return 60
    }

    /// Maps documented HTTP error codes to human-readable labels. Keeps the
    /// raw body in the message but prefixes with a hint so users don't see
    /// generic "NSURLErrorTimedOut" for what is actually an upstream timeout
    /// at the API edge.
    static func errorLabel(forStatus status: Int, body: String) -> String {
        let prefix: String
        switch status {
        case 408: prefix = "Request timed out at API edge"
        case 429: prefix = "Rate limited"
        case 524: prefix = "Upstream provider timed out"
        case 529: prefix = "Upstream provider overloaded"
        default:  prefix = "HTTP \(status)"
        }
        return "\(prefix): \(body.prefix(300))"
    }
}

// MARK: - SSE Parser

/// Single-line SSE event parser pulled out as a static helper so it can be
/// unit-tested without spinning up URLSession. The OpenAI-compatible chat
/// completions stream emits one of:
///   - `: <comment>` — heartbeat / keep-alive (ignore)
///   - empty line — message boundary (ignore)
///   - `data: <json>` — content delta or error
///   - `data: [DONE]` — terminator
/// Lines that don't fit the above shape are also ignored (forward compat:
/// providers occasionally add new event types like `event:` lines).
enum SSEParser {
    enum Event: Equatable {
        case content(String)
        case error(String)
        case done
        case skip
    }

    static func parse(line: String) -> Event {
        if line.isEmpty { return .skip }
        if line.hasPrefix(":") { return .skip }     // SSE comment / heartbeat
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst("data: ".count))
        if payload == "[DONE]" { return .done }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .skip
        }

        // Mid-stream error: OpenRouter wraps upstream failures as `{"error":…}`.
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? String(describing: err)
            return .error(msg)
        }

        // Standard delta path. We deliberately ignore `delta.reasoning` — we
        // sent `reasoning.exclude=true` so it shouldn't arrive, but if a
        // provider sends it anyway, dropping it matches the "refine the
        // visible reply only" contract.
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return .skip
        }
        return .content(content)
    }
}
