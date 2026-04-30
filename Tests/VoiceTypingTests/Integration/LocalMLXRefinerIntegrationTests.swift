import XCTest
@testable import VoiceTyping

/// Boots the real `mlx-community/Qwen3.5-4B-MLX-4bit` and runs end-to-end
/// refines. **Skipped by default** because it requires:
///   1. `LOCAL_REFINER_INTEGRATION_TESTS=1` env var (opt-in gate)
///   2. The model downloaded at `ModelStore.localRefinerDirectory`
///      (override with `LOCAL_REFINER_MODEL_DIR=/path/to/model`)
///   3. Apple Silicon (mlx-swift Metal backend); CI x86_64 runners would fail
///
/// Catches things unit tests can't:
///   - mlx-swift-lm upstream regressions (chat template handling, tokenizer
///     loading, generate parameters)
///   - The `enable_thinking=false` `additionalContext` actually flowing
///     through the swift-transformers Jinja runtime (the #R4 spike risk)
///   - Cold-load wall clock in a clean process (vs warm app session)
///
/// Run locally:
/// ```
/// LOCAL_REFINER_INTEGRATION_TESTS=1 swift test --filter LocalMLXRefinerIntegrationTests
/// ```
final class LocalMLXRefinerIntegrationTests: XCTestCase {

    /// Resolves the directory the test should load weights from. Honors the
    /// `LOCAL_REFINER_MODEL_DIR` override so a developer can point at a
    /// scratch download that lives outside Application Support.
    private var modelDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["LOCAL_REFINER_MODEL_DIR"],
           !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return ModelStore.localRefinerDirectory
    }

    /// Two preconditions: env opt-in, and the model is actually on disk.
    /// `XCTSkipIf` / `XCTSkipUnless` produce a clean "skipped" signal in
    /// xcodebuild + swift test output rather than a fail.
    private func skipUnlessReady() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["LOCAL_REFINER_INTEGRATION_TESTS"] != "1",
            "Integration test gated — set LOCAL_REFINER_INTEGRATION_TESTS=1 to run"
        )
        try XCTSkipUnless(
            ModelStore.isLocalRefinerComplete(atDirectory: modelDirectory),
            "Model not present at \(modelDirectory.path) — download via Settings → LLM → Local refiner first"
        )
    }

    // MARK: - Tests

    /// End-to-end: load weights, refine a Chinese-English mixed sentence,
    /// verify no `<think>` artifacts (the headline #R4 risk — would mean
    /// `enable_thinking=false` regressed and Qwen3 is dumping its chain-of-
    /// thought into our refined output).
    func testIntegration_Refine_NoThinkArtifacts_FastEnoughCold() async throws {
        try skipUnlessReady()

        let refiner = LocalMLXRefiner(modelDirectory: modelDirectory)
        let t0 = Date()
        let output = await refiner.refine(
            "嗯, 这是一个 test 句子, 包含 mixed 中英文",
            language: .zhCN,
            mode: .aggressive,
            glossary: nil,
            profileSnippet: nil
        )
        let totalMs = Int(Date().timeIntervalSince(t0) * 1000)

        XCTAssertFalse(output.isEmpty, "Refine returned empty string")
        XCTAssertFalse(output.contains("<think>"),
                       "Output contains <think> — enable_thinking=false stopped working. Output: \"\(output)\"")
        XCTAssertFalse(output.contains("</think>"),
                       "Output contains </think> — enable_thinking=false stopped working. Output: \"\(output)\"")
        // Cold load + first refine should finish in 30s on a developer Mac.
        // Loose bound — we're catching gross regressions (model size doubled,
        // mlx-swift went 3x slower), not perf-tuning.
        XCTAssertLessThan(totalMs, 30_000,
                          "Cold load + first refine took \(totalMs)ms — mlx-swift may have regressed")

        print("[Integration] LocalMLXRefiner cold path: \(totalMs)ms, output=\"\(output)\"")
    }

    /// `test()` is what Settings → LLM "Test" button drives. Verify it
    /// returns a non-empty `.ok(...)` when the model is downloaded — the
    /// fail-open path is already covered by unit tests.
    func testIntegration_TestEndpoint_ReturnsOK() async throws {
        try skipUnlessReady()

        let refiner = LocalMLXRefiner(modelDirectory: modelDirectory)
        let result = await refiner.test()
        switch result {
        case .ok(let reply):
            XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "test() returned empty reply")
            XCTAssertFalse(reply.contains("<think>"),
                           "test() reply contains <think>: \"\(reply)\"")
        case .failed(let msg):
            XCTFail("test() failed when model is downloaded: \(msg)")
        }
    }

    /// Cold load is dominated by weights mmap + Metal JIT (~700-7000ms).
    /// Subsequent refines reuse the loaded `ModelContainer` and should be
    /// fast (< 4s for short input on Qwen3.5-4B 4bit, ~30 tok/s warm).
    /// This test pins that warm path so a regression in the lazy-load
    /// coalescing doesn't silently turn every refine into a cold load.
    func testIntegration_WarmRefine_NoLoadCost() async throws {
        try skipUnlessReady()

        let refiner = LocalMLXRefiner(modelDirectory: modelDirectory)
        // Discard cold-path call. Don't time this one — it includes load.
        _ = await refiner.refine("warmup", language: .en, mode: .conservative,
                                  glossary: nil, profileSnippet: nil)

        // Time the warm second call.
        let t0 = Date()
        let output = await refiner.refine(
            "Hello, world.",
            language: .en, mode: .conservative,
            glossary: nil, profileSnippet: nil
        )
        let warmMs = Int(Date().timeIntervalSince(t0) * 1000)

        XCTAssertFalse(output.isEmpty)
        // 4s ceiling: warm Qwen3.5-4B in MLX 4bit at ~30 tok/s does this
        // 13-char input + ~15 token reply in well under a second on M-series.
        // 4s leaves room for slower chips + occasional GC.
        XCTAssertLessThan(warmMs, 4_000,
                          "Warm refine took \(warmMs)ms — lazy-load coalescing may have regressed (each call re-loading?)")

        print("[Integration] LocalMLXRefiner warm refine: \(warmMs)ms, output=\"\(output)\"")
    }
}
