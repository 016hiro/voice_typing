import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// On-device MLX-backed `LLMRefining` — loads `mlx-community/Qwen3.5-4B-MLX-4bit`
/// from `ModelStore.localRefinerDirectory` and runs inference via mlx-swift-lm.
///
/// **Lifecycle**:
/// - First `refine` call triggers a lazy load (~6.5s cold; subsequent calls
///   reuse the loaded weights). Per v0.6.3 user decision, we deliberately
///   do NOT keep the model warm against macOS compressor — refine has
///   built-in "wait" UX so cold-decompress 5-30s is acceptable. That's
///   different from ASR (v0.6.4 keep-alive patch). Capsule UI shows a
///   "warming up..." hint on first refine in a long-idle session.
///
/// **Chat template**: `additionalContext: ["enable_thinking": false]` flows
/// through swift-transformers' Jinja runtime to suppress Qwen3's default
/// chain-of-thought emission (verified end-to-end in the v0.6.3 #R4 spike).
/// The known empty `<think></think>` quirk on some Qwen3 templates is
/// scrubbed in post via `LLMRefiningHelpers.stripEmptyThinkBlock`.
///
/// **Concurrency**: actor — serializes the lazy load + per-call inference,
/// avoids racing two `refine` calls into a double-load. ChatSession itself
/// is created fresh per call (no cross-call history) so concurrent refines
/// are independent.
actor LocalMLXRefiner: LLMRefining {

    /// `nonisolated` so `LocalLiveSegmentSession` can read the path without
    /// hopping into the actor — pure config that never changes after init.
    nonisolated let modelDirectory: URL
    private var loadedContainer: ModelContainer?
    private var loadInFlight: Task<ModelContainer, Error>?

    init(modelDirectory: URL = ModelStore.localRefinerDirectory) {
        self.modelDirectory = modelDirectory
    }

    nonisolated func refine(_ text: String,
                            language: Language,
                            mode: RefineMode,
                            glossary: String?,
                            profileSnippet: String?) async -> String {
        var accumulated = ""
        do {
            for try await chunk in refineStream(text,
                                                language: language,
                                                mode: mode,
                                                glossary: glossary,
                                                profileSnippet: profileSnippet) {
                accumulated += chunk
            }
        } catch {
            // Stream layer already logged via refineStreamImpl.
            return text
        }
        // Apply the bookend `stripQuotesAndCode` on the full accumulated
        // string — this is the batch contract. The streaming path can only
        // strip the *leading* `<think></think>` (done inside refineStream);
        // trailing quote / code-fence stripping needs the whole reply.
        let cleaned = LLMRefiningHelpers.stripQuotesAndCode(accumulated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    /// v0.7.0 #R4: streaming variant via mlx-swift-lm `streamResponse`. Yields
    /// raw tokens as they arrive from the model, with one bookkeeping detail —
    /// a small head buffer (first ~30 chars or until the first newline)
    /// captures Qwen3's empty `<think>\n\n</think>` bookend so we strip it
    /// before yielding. Trailing markers (` ``` ` / `"`) can't be stripped in
    /// streaming without lookahead; `refine`'s batch path handles those at
    /// the accumulated-string boundary.
    nonisolated func refineStream(_ text: String,
                                  language: Language,
                                  mode: RefineMode,
                                  glossary: String?,
                                  profileSnippet: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await self.refineStreamImpl(text,
                                            mode: mode,
                                            glossary: glossary,
                                            profileSnippet: profileSnippet,
                                            continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func refineStreamImpl(_ text: String,
                                  mode: RefineMode,
                                  glossary: String?,
                                  profileSnippet: String?,
                                  continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continuation.finish(); return }
        guard let systemPrompt = mode.systemPrompt else { continuation.finish(); return }    // .off
        guard ModelStore.isLocalRefinerComplete(atDirectory: modelDirectory) else {
            Log.llm.warning("LocalMLXRefiner: model not downloaded at \(self.modelDirectory.path, privacy: .public) — finishing empty stream")
            continuation.finish()
            return
        }

        let finalSystem = LLMRefiningHelpers.compose(
            systemPrompt: systemPrompt,
            profileSnippet: profileSnippet,
            glossary: glossary
        )

        do {
            let t0 = Date()
            let container = try await ensureLoaded()
            let loadMs = Int(Date().timeIntervalSince(t0) * 1000)   // ~0 if warm, large if first call
            let session = ChatSession(
                container,
                instructions: finalSystem,
                generateParameters: GenerateParameters(
                    maxTokens: 512,
                    temperature: 0
                ),
                additionalContext: ["enable_thinking": false]
            )
            let inferStart = Date()

            var head = ""
            var headFlushed = false
            var totalChars = 0
            for try await chunk in session.streamResponse(to: trimmed) {
                totalChars += chunk.count
                if headFlushed {
                    continuation.yield(chunk)
                } else {
                    head += chunk
                    // 30 chars or a newline is enough to know whether the
                    // optional `<think>\n\n</think>` bookend has been
                    // captured — once past that we can yield raw.
                    if head.count >= 30 || head.contains("\n") {
                        let cleaned = LLMRefiningHelpers.stripEmptyThinkBlock(head)
                        if !cleaned.isEmpty { continuation.yield(cleaned) }
                        head = ""
                        headFlushed = true
                    }
                }
            }
            // Short replies that ended before the head threshold — flush
            // whatever's in the buffer, post-strip.
            if !headFlushed {
                let cleaned = LLMRefiningHelpers.stripEmptyThinkBlock(head)
                if !cleaned.isEmpty { continuation.yield(cleaned) }
            }

            let inferMs = Int(Date().timeIntervalSince(inferStart) * 1000)
            // Format mirrors v0.6.3's `LocalRefined` log line so existing
            // dogfood tooling keeps parsing; `_stream` suffix tags the new
            // generation path.
            Log.llm.notice("LocalRefined_stream (\(mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(totalChars, privacy: .public) chars in load_ms=\(loadMs, privacy: .public) infer_ms=\(inferMs, privacy: .public)")
            continuation.finish()
        } catch {
            Log.llm.warning("Local refine stream failed: \(String(describing: error), privacy: .public)")
            continuation.finish(throwing: error)
        }
    }

    nonisolated func test() async -> LLMRefiningTestResult {
        await testImpl()
    }

    private func testImpl() async -> LLMRefiningTestResult {
        guard ModelStore.isLocalRefinerComplete(atDirectory: modelDirectory) else {
            return .failed("Model not downloaded — open Settings → LLM and toggle local refiner ON to download.")
        }
        do {
            let container = try await ensureLoaded()
            let session = ChatSession(
                container,
                instructions: "Reply with the single word: ok",
                generateParameters: GenerateParameters(maxTokens: 16, temperature: 0),
                additionalContext: ["enable_thinking": false]
            )
            let reply = try await session.respond(to: "ping")
            return .ok(sampleReply: LLMRefiningHelpers.stripEmptyThinkBlock(reply))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// v0.7.0 #R9 redo: factory for a multi-segment live refine session.
    /// Returns an actor that holds one `ChatSession` across the whole live
    /// recording — chat history accumulates so segment N+1's refine sees
    /// segment N's refined output, resolving cross-segment references like
    /// pronouns. Created at Fn↓; `end()` called at Fn↑ to release the
    /// session and its KV cache.
    nonisolated func makeLiveSegmentSession(mode: RefineMode,
                                            glossary: String?,
                                            profileSnippet: String?) -> LocalLiveSegmentSession {
        return LocalLiveSegmentSession(
            refiner: self,
            mode: mode,
            glossary: glossary,
            profileSnippet: profileSnippet
        )
    }

    /// Lazily load weights on first call. Coalesces concurrent loads into a
    /// single Task — second/third concurrent `refine` await the same in-flight
    /// load rather than triggering N parallel `loadModelContainer` calls.
    /// Internal (not private) so `LocalLiveSegmentSession` can share the
    /// warm container across a multi-segment live recording.
    func ensureLoaded() async throws -> ModelContainer {
        if let loaded = loadedContainer { return loaded }
        if let inFlight = loadInFlight {
            return try await inFlight.value
        }
        let dir = modelDirectory
        let task = Task<ModelContainer, Error> {
            let t0 = Date()
            let configuration = ModelConfiguration(directory: dir)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            )
            Log.llm.notice("LocalMLXRefiner: loaded in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public) ms")
            return container
        }
        loadInFlight = task
        defer { loadInFlight = nil }
        let container = try await task.value
        loadedContainer = container
        return container
    }
}

/// v0.7.0 #R9 redo: holds one mlx-swift-lm `ChatSession` across the lifetime
/// of a live recording. Each segment's refine call runs `streamResponse` on
/// the same session — chat history accumulates so segment N's refined output
/// is in context when segment N+1 is refined. Solves the "cross-segment
/// reference" problem (it/that/them) without prompt-template hacks.
///
/// **Concurrency**: actor — `streamResponse` calls hold a KV-cache lock
/// internally, so concurrent segment refines would serialize anyway. The
/// actor surface makes that explicit and lets the live inject task await
/// in-order without surprises.
///
/// **Lifecycle**: created at Fn↓ via `LocalMLXRefiner.makeLiveSegmentSession`,
/// `end()` at Fn↑ to drop the session and release its KV cache. The first
/// `refineSegmentStream` lazily creates the underlying `ChatSession` after
/// awaiting `refiner.ensureLoaded()` — same warm container the one-shot
/// `refine` uses.
actor LocalLiveSegmentSession {
    private let refiner: LocalMLXRefiner
    private let mode: RefineMode
    private let finalSystem: String
    private var chatSession: ChatSession?
    private var firstSegmentLoadedMs: Int = 0  // for the first-segment log line

    /// v0.7.0 #R9 redo follow-up: sum of per-segment `infer_ms` so the
    /// pipelineTask's tracker can backfill `llm_ms` in the session-level
    /// latency log line. Without this the log shows `llm_ms=-1` for the
    /// per-segment path even though refine clearly ran — see Console
    /// `LocalLiveSegment (...) infer_ms=...` per segment for ground truth.
    private(set) var totalInferMs: Int = 0

    init(refiner: LocalMLXRefiner,
         mode: RefineMode,
         glossary: String?,
         profileSnippet: String?) {
        self.refiner = refiner
        self.mode = mode
        let baseSystem = mode.systemPrompt ?? ""
        self.finalSystem = LLMRefiningHelpers.compose(
            systemPrompt: baseSystem,
            profileSnippet: profileSnippet,
            glossary: glossary
        )
    }

    /// Streams refined output for one segment of a live recording. The
    /// session's chat history is auto-extended by mlx-swift-lm with the
    /// current `text` and the model's reply, so segment N+1 gets prior
    /// segments as context. Empty / `.off` / model-not-downloaded inputs
    /// finish the stream immediately empty (caller falls back to raw).
    nonisolated func refineSegmentStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await self.runSegment(text, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runSegment(_ text: String,
                            continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continuation.finish(); return }
        guard mode.systemPrompt != nil else { continuation.finish(); return }
        guard ModelStore.isLocalRefinerComplete(atDirectory: refiner.modelDirectory) else {
            continuation.finish()
            return
        }

        do {
            // First-segment lazy create: load container (shared with one-shot
            // refine, so warm if user did a non-live refine recently) and
            // build a ChatSession with the system prompt frozen at session
            // start. Chat history grows from here.
            if chatSession == nil {
                let t0 = Date()
                let container = try await refiner.ensureLoaded()
                firstSegmentLoadedMs = Int(Date().timeIntervalSince(t0) * 1000)
                chatSession = ChatSession(
                    container,
                    instructions: finalSystem,
                    generateParameters: GenerateParameters(maxTokens: 512, temperature: 0),
                    additionalContext: ["enable_thinking": false]
                )
            }
            guard let session = chatSession else { continuation.finish(); return }

            let inferStart = Date()
            // Same head-buffer pattern as one-shot streaming refine — strips
            // the optional empty `<think>\n\n</think>` Qwen3 bookend before
            // any chunk reaches the user. Per-segment, so applied each call.
            var head = ""
            var headFlushed = false
            var totalChars = 0
            for try await chunk in session.streamResponse(to: trimmed) {
                totalChars += chunk.count
                if headFlushed {
                    continuation.yield(chunk)
                } else {
                    head += chunk
                    if head.count >= 30 || head.contains("\n") {
                        let cleaned = LLMRefiningHelpers.stripEmptyThinkBlock(head)
                        if !cleaned.isEmpty { continuation.yield(cleaned) }
                        head = ""
                        headFlushed = true
                    }
                }
            }
            if !headFlushed {
                let cleaned = LLMRefiningHelpers.stripEmptyThinkBlock(head)
                if !cleaned.isEmpty { continuation.yield(cleaned) }
            }

            let inferMs = Int(Date().timeIntervalSince(inferStart) * 1000)
            totalInferMs += inferMs
            Log.llm.notice("LocalLiveSegment (\(self.mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(totalChars, privacy: .public) chars in load_ms=\(self.firstSegmentLoadedMs, privacy: .public) infer_ms=\(inferMs, privacy: .public)")
            // Reset load_ms after the first segment so subsequent log lines
            // accurately report 0 — the container only loads once per live
            // session.
            firstSegmentLoadedMs = 0
            continuation.finish()
        } catch {
            Log.llm.warning("LocalLiveSegment refine failed: \(String(describing: error), privacy: .public)")
            continuation.finish(throwing: error)
        }
    }

    /// Releases the underlying ChatSession + KV cache. Idempotent. Caller
    /// invokes from Fn↑ once the inject task has drained.
    func end() {
        chatSession = nil
    }
}
