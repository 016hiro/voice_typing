import XCTest
@testable import VoiceTyping

/// v0.7.0 #R5: covers the `shouldFlush` boundary heuristic that decides
/// when to Cmd+V the pending buffer during streaming inject. Logic-only;
/// the actual paste path is exercised end-to-end during dogfood.
final class TextInjectorFlushBoundaryTests: XCTestCase {

    func testEmptyBuffer_DoesNotFlush() {
        XCTAssertFalse(TextInjector.shouldFlush(""))
    }

    func testShortBufferNoPunctuation_DoesNotFlush() {
        XCTAssertFalse(TextInjector.shouldFlush("hi"))
        XCTAssertFalse(TextInjector.shouldFlush("hello"))
    }

    func testASCIIPunctuation_Flushes() {
        for last in [",", ".", ";", ":", "!", "?"] {
            XCTAssertTrue(TextInjector.shouldFlush("a\(last)"),
                          "expected flush after '\(last)'")
        }
    }

    func testCJKPunctuation_Flushes() {
        for last in ["，", "。", "；", "：", "！", "？"] {
            XCTAssertTrue(TextInjector.shouldFlush("你好\(last)"),
                          "expected flush after '\(last)'")
        }
    }

    func testNewline_Flushes() {
        XCTAssertTrue(TextInjector.shouldFlush("paragraph one\n"))
    }

    func testWhitespaceShortBuffer_DoesNotFlush() {
        // 6 chars ending in space — under the 8-char word-boundary threshold,
        // holds for the next chunk in case the word continues.
        XCTAssertFalse(TextInjector.shouldFlush("ab cd "))
        // 7 chars ending in space — still under threshold.
        XCTAssertFalse(TextInjector.shouldFlush("abc de "))
    }

    func testWhitespaceAtWordBoundary_Flushes() {
        // ≥ 8 chars + ending whitespace → word-boundary flush.
        XCTAssertTrue(TextInjector.shouldFlush("abc def "))      // 8 chars
        XCTAssertTrue(TextInjector.shouldFlush("hello to "))      // 9 chars
        XCTAssertTrue(TextInjector.shouldFlush("12345678 "))      // 9 chars
    }

    func testHardCap_Flushes() {
        // 32 chars no punctuation, no whitespace → hard-cap flush.
        let s = String(repeating: "a", count: 32)
        XCTAssertTrue(TextInjector.shouldFlush(s))
    }

    func testJustUnderHardCap_DoesNotFlushIfNoOtherBoundary() {
        // 31 chars no punctuation no whitespace — holds.
        let s = String(repeating: "a", count: 31)
        XCTAssertFalse(TextInjector.shouldFlush(s))
    }

    func testMidWordChunk_DoesNotFlush() {
        // Realistic LLM token boundary mid-word — must wait for next token.
        XCTAssertFalse(TextInjector.shouldFlush("stream"))
        XCTAssertFalse(TextInjector.shouldFlush("Hel"))
    }

    func testCJKCharOnly_DoesNotFlush() {
        // CJK characters w/o punctuation — wait for sentence boundary.
        XCTAssertFalse(TextInjector.shouldFlush("今天测试"))
    }
}
