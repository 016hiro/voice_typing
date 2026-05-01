import XCTest
@testable import VoiceTyping

/// v0.7.0 #R2: covers the default `refineStream` implementation that
/// wraps a batch `refine` as a single-chunk yield. Real cloud/local
/// streaming impls (R3/R4) override this and have their own tests.
final class LLMRefiningDefaultStreamTests: XCTestCase {

    /// Stub that only implements the required `refine` + `test`. Inherits
    /// the default `refineStream` from the protocol extension — that's
    /// what we're exercising.
    private struct StubRefiner: LLMRefining {
        let reply: String

        func refine(_ text: String,
                    language: Language,
                    mode: RefineMode,
                    glossary: String?,
                    profileSnippet: String?) async -> String {
            return reply
        }

        func test() async -> LLMRefiningTestResult {
            return .ok(sampleReply: "ok")
        }
    }

    func testDefaultStream_YieldsRefineResultAsSingleChunk() async throws {
        let stub = StubRefiner(reply: "polished")
        var chunks: [String] = []
        for try await chunk in stub.refineStream("raw",
                                                 language: .en,
                                                 mode: .light,
                                                 glossary: nil,
                                                 profileSnippet: nil) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["polished"])
    }

    func testDefaultStream_FinishesAfterSingleChunk() async throws {
        let stub = StubRefiner(reply: "x")
        var count = 0
        for try await _ in stub.refineStream("raw",
                                             language: .en,
                                             mode: .light,
                                             glossary: nil,
                                             profileSnippet: nil) {
            count += 1
        }
        // The for-loop exiting cleanly = the stream finished. If `finish()`
        // weren't called the iterator would hang and the test would time out.
        XCTAssertEqual(count, 1)
    }

    func testDefaultStream_PassesArgumentsThrough() async throws {
        // Capture-flavored stub: records what `refine` was called with so we
        // can assert the default `refineStream` doesn't drop or rewrite args.
        actor Captured {
            var text: String?
            var language: Language?
            var mode: RefineMode?
            var glossary: String?
            var profileSnippet: String?
            func record(_ text: String, _ lang: Language, _ mode: RefineMode,
                        _ glossary: String?, _ profileSnippet: String?) {
                self.text = text
                self.language = lang
                self.mode = mode
                self.glossary = glossary
                self.profileSnippet = profileSnippet
            }
        }
        struct CaptureRefiner: LLMRefining {
            let captured: Captured
            func refine(_ text: String,
                        language: Language,
                        mode: RefineMode,
                        glossary: String?,
                        profileSnippet: String?) async -> String {
                await captured.record(text, language, mode, glossary, profileSnippet)
                return "ok"
            }
            func test() async -> LLMRefiningTestResult { .ok(sampleReply: "ok") }
        }

        let captured = Captured()
        let stub = CaptureRefiner(captured: captured)
        for try await _ in stub.refineStream("the input",
                                             language: .zhCN,
                                             mode: .aggressive,
                                             glossary: "term1: pronunciation",
                                             profileSnippet: "user prefers terse output") {
        }

        let text = await captured.text
        let lang = await captured.language
        let mode = await captured.mode
        let glossary = await captured.glossary
        let snippet = await captured.profileSnippet

        XCTAssertEqual(text, "the input")
        XCTAssertEqual(lang, .zhCN)
        XCTAssertEqual(mode, .aggressive)
        XCTAssertEqual(glossary, "term1: pronunciation")
        XCTAssertEqual(snippet, "user prefers terse output")
    }
}
