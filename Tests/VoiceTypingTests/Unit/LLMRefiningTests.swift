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
                                          mode: .conservative,
                                          glossary: nil,
                                          profileSnippet: nil)
        XCTAssertEqual(result, "")
    }

    func testCloud_WhitespaceOnlyInput_ReturnsInputUnchanged() async {
        let refiner = CloudLLMRefiner(config: validConfig)
        let input = "   \n\t  "
        let result = await refiner.refine(input, language: .en,
                                          mode: .conservative,
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
                                          mode: .conservative,
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
                                       mode: .conservative,
                                       glossary: nil,
                                       profileSnippet: nil)
        XCTAssertEqual(result, "STUB-OUTPUT")

        let test = await fake.test()
        switch test {
        case .ok(let reply): XCTAssertEqual(reply, "fake-ok")
        case .failed: XCTFail("Stub should report .ok")
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
