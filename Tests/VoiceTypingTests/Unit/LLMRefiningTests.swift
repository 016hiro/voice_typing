import XCTest
@testable import VoiceTyping

final class LLMRefiningTests: XCTestCase {

    // MARK: - CloudLLMRefiner fail-open paths (no network)
    //
    // These verify the early-return guards in `refine(...)` — the network
    // path is unreachable in unit tests, so we exercise only the branches
    // that exit before any HTTP attempt.

    func testCloud_EmptyInput_ReturnsInputUnchanged() async {
        let refiner = CloudLLMRefiner(config: validConfig)
        let result = await refiner.refine("", language: .en,
                                          mode: .light,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, "")
    }

    func testCloud_WhitespaceOnlyInput_ReturnsInputUnchanged() async {
        let refiner = CloudLLMRefiner(config: validConfig)
        let input = "   \n\t  "
        let result = await refiner.refine(input, language: .en,
                                          mode: .light,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, input)
    }

    func testCloud_OffMode_ReturnsInputUnchanged() async {
        let refiner = CloudLLMRefiner(config: validConfig)
        let input = "hello world"
        let result = await refiner.refine(input, language: .en,
                                          mode: .off,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, input)
    }

    func testCloud_NoCredentials_ReturnsInputUnchanged() async {
        let refiner = CloudLLMRefiner(config: emptyConfig)
        let input = "hello world"
        let result = await refiner.refine(input, language: .en,
                                          mode: .light,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, input)
    }

    func testCloud_TestEmptyCredentials_ReturnsFailed() async {
        let refiner = CloudLLMRefiner(config: emptyConfig)
        let result = await refiner.test()
        switch result {
        case .ok:    XCTFail("Expected .failed for empty credentials, got .ok")
        case .failed(let msg):
            XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: - Protocol conformance + polymorphism
    //
    // Verify the protocol shape lets a fake stand in for the real impl —
    // this is the v0.6.3 #R7 use case (AppDelegate `var refiner: any LLMRefining`
    // switching between cloud and local without touching call sites).

    func testProtocol_FakeImpl_Substitutable() async {
        let fake: any LLMRefining = StubRefiner(constantOutput: "STUB-OUTPUT")
        let result = await fake.refine("anything", language: .en,
                                       mode: .light,
                                       glossary: nil,
                                       profileSnippet: nil)
        XCTAssertEqual(result, "STUB-OUTPUT")

        let test = await fake.test()
        switch test {
        case .ok(let reply): XCTAssertEqual(reply, "fake-ok")
        case .failed: XCTFail("Stub should report .ok")
        }
    }

    // MARK: - Shared helpers (LLMRefiningHelpers)

    func testHelpers_Compose_BaseOnly() {
        let result = LLMRefiningHelpers.compose(
            systemPrompt: "BASE", profileSnippet: nil, glossary: nil)
        XCTAssertEqual(result, "BASE")
    }

    func testHelpers_Compose_StacksMostGeneralToMostSpecific() {
        let result = LLMRefiningHelpers.compose(
            systemPrompt: "BASE",
            profileSnippet: "PROFILE",
            glossary: "GLOSSARY"
        )
        XCTAssertEqual(result, "BASE\n\nPROFILE\n\nGLOSSARY")
    }

    func testHelpers_Compose_SkipsEmptyOrWhitespace() {
        let result = LLMRefiningHelpers.compose(
            systemPrompt: "BASE",
            profileSnippet: "   \n  ",
            glossary: ""
        )
        XCTAssertEqual(result, "BASE")
    }

    func testHelpers_StripQuotes_StraightQuotes() {
        XCTAssertEqual(
            LLMRefiningHelpers.stripQuotesAndCode("\"hello world\""),
            "hello world"
        )
    }

    func testHelpers_StripQuotes_CurlyQuotes() {
        XCTAssertEqual(
            LLMRefiningHelpers.stripQuotesAndCode("\u{201C}hello\u{201D}"),
            "hello"
        )
    }

    func testHelpers_StripQuotes_CodeFence() {
        let input = "```\nhello world\n```"
        XCTAssertEqual(
            LLMRefiningHelpers.stripQuotesAndCode(input),
            "hello world\n"
        )
    }

    func testHelpers_StripQuotes_Untouched() {
        XCTAssertEqual(
            LLMRefiningHelpers.stripQuotesAndCode("plain text"),
            "plain text"
        )
    }

    func testHelpers_StripEmptyThinkBlock_RemovesEmpty() {
        let input = "<think>\n\n</think>\nThe actual answer."
        XCTAssertEqual(
            LLMRefiningHelpers.stripEmptyThinkBlock(input),
            "The actual answer."
        )
    }

    func testHelpers_StripEmptyThinkBlock_LeavesNonEmptyThink() {
        // Defensive: if Qwen3 actually emits real thinking content, don't
        // silently drop it — only the empty quirk gets scrubbed.
        let input = "<think>real reasoning here</think>\nAnswer."
        XCTAssertEqual(
            LLMRefiningHelpers.stripEmptyThinkBlock(input),
            input
        )
    }

    func testHelpers_StripEmptyThinkBlock_NoOpWhenAbsent() {
        XCTAssertEqual(
            LLMRefiningHelpers.stripEmptyThinkBlock("plain answer"),
            "plain answer"
        )
    }

    // MARK: - LocalMLXRefiner fail-open paths (no model loaded)
    //
    // Real load + inference can't be tested in unit context (no model
    // available, mlx-swift-lm needs Metal). These cover guards that exit
    // before any model interaction.

    func testLocal_EmptyInput_ReturnsInput() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-LocalRefiner-\(UUID().uuidString)",
                                    isDirectory: true)
        let refiner = LocalMLXRefiner(modelDirectory: dir)
        let result = await refiner.refine("", language: .en,
                                          mode: .light,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, "")
    }

    func testLocal_OffMode_ReturnsInput() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-LocalRefiner-\(UUID().uuidString)",
                                    isDirectory: true)
        let refiner = LocalMLXRefiner(modelDirectory: dir)
        let result = await refiner.refine("hello", language: .en,
                                          mode: .off,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, "hello")
    }

    func testLocal_ModelNotDownloaded_ReturnsInput() async {
        // Empty temp dir → isLocalRefinerComplete == false → fail-open
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-LocalRefiner-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let refiner = LocalMLXRefiner(modelDirectory: dir)
        let result = await refiner.refine("hello", language: .en,
                                          mode: .light,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, "hello")
    }

    func testLocal_TestModelNotDownloaded_ReturnsFailed() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-LocalRefiner-\(UUID().uuidString)",
                                    isDirectory: true)
        let refiner = LocalMLXRefiner(modelDirectory: dir)
        let result = await refiner.test()
        switch result {
        case .ok:    XCTFail("Expected .failed when model not downloaded")
        case .failed(let msg): XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: - Fixtures

    private var validConfig: LLMConfig {
        LLMConfig(enabled: true,
                  baseURL: "https://example.test/v1/chat/completions",
                  apiKey: "sk-test",
                  model: "test-model",
                  timeout: 8)
    }

    private var emptyConfig: LLMConfig {
        LLMConfig(enabled: true,
                  baseURL: "",
                  apiKey: "",
                  model: "",
                  timeout: 8)
    }
}

// MARK: - Stub impl

private struct StubRefiner: LLMRefining {
    let constantOutput: String

    func refine(_ text: String,
                language: Language,
                mode: RefineMode,
                glossary: String?,
                profileSnippet: String?) async -> String {
        constantOutput
    }

    func test() async -> LLMRefiningTestResult {
        .ok(sampleReply: "fake-ok")
    }
}
