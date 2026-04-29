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

    private let modelDirectory: URL
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
        await refineImpl(text, mode: mode, glossary: glossary, profileSnippet: profileSnippet)
    }

    private func refineImpl(_ text: String,
                            mode: RefineMode,
                            glossary: String?,
                            profileSnippet: String?) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let systemPrompt = mode.systemPrompt else { return text }    // .off
        guard ModelStore.isLocalRefinerComplete(atDirectory: modelDirectory) else {
            Log.llm.warning("LocalMLXRefiner: model not downloaded at \(self.modelDirectory.path, privacy: .public) — returning input unchanged")
            return text
        }

        let finalSystem = LLMRefiningHelpers.compose(
            systemPrompt: systemPrompt,
            profileSnippet: profileSnippet,
            glossary: glossary
        )

        do {
            let container = try await ensureLoaded()
            let session = ChatSession(
                container,
                instructions: finalSystem,
                generateParameters: GenerateParameters(
                    maxTokens: 512,
                    temperature: 0
                ),
                additionalContext: ["enable_thinking": false]
            )
            let reply = try await session.respond(to: trimmed)
            let cleaned = LLMRefiningHelpers.stripEmptyThinkBlock(reply)
                .pipe(LLMRefiningHelpers.stripQuotesAndCode)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.llm.info("LocalRefined (\(mode.rawValue, privacy: .public)) \(trimmed.count, privacy: .public) → \(cleaned.count, privacy: .public) chars")
            return cleaned.isEmpty ? text : cleaned
        } catch {
            Log.llm.warning("Local refine failed: \(String(describing: error), privacy: .public)")
            return text
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

    /// Lazily load weights on first call. Coalesces concurrent loads into a
    /// single Task — second/third concurrent `refine` await the same in-flight
    /// load rather than triggering N parallel `loadModelContainer` calls.
    private func ensureLoaded() async throws -> ModelContainer {
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
            Log.llm.info("LocalMLXRefiner: loaded in \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public) ms")
            return container
        }
        loadInFlight = task
        defer { loadInFlight = nil }
        let container = try await task.value
        loadedContainer = container
        return container
    }
}

private extension String {
    /// Pipe-through helper so the post-process chain reads top-down.
    func pipe(_ transform: (String) -> String) -> String {
        transform(self)
    }
}
