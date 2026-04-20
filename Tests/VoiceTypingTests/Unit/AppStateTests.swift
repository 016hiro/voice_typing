import XCTest
@testable import VoiceTyping

@MainActor
final class AppStateTests: XCTestCase {

    // MARK: - tailTruncated

    func testTailTruncated_shortStringUnchanged() {
        XCTAssertEqual(AppState.tailTruncated("hello", max: 30), "hello")
    }

    func testTailTruncated_exactBoundaryUnchanged() {
        let s = String(repeating: "a", count: 30)
        XCTAssertEqual(AppState.tailTruncated(s, max: 30), s)
    }

    func testTailTruncated_longStringPrependsEllipsis() {
        // 35 chars → keep last 30 with leading ellipsis.
        let long = String(repeating: "x", count: 35)
        let out = AppState.tailTruncated(long, max: 30)
        XCTAssertTrue(out.hasPrefix("…"))
        XCTAssertEqual(out.dropFirst().count, 30)
    }

    func testTailTruncated_keepsTailContent() {
        // The "latest" characters are what should stay visible — verify we show the
        // suffix, not the prefix.
        let input = "abcdefghijklmnopqrstuvwxyz0123456789"  // 36 chars
        let out = AppState.tailTruncated(input, max: 10)
        XCTAssertEqual(out, "…0123456789")
    }

    func testTailTruncated_cjkPreservesGraphemes() {
        // String.suffix is Character-level (grapheme clusters), so CJK shouldn't split.
        let zh = "你好世界今天天气怎么样啊我想去外面散散步看看风景"  // 24 chars
        let out = AppState.tailTruncated(zh, max: 10)
        XCTAssertTrue(out.hasPrefix("…"))
        // Last 10 characters kept intact, no byte-level splitting.
        XCTAssertEqual(out.dropFirst().count, 10)
        XCTAssertEqual(out, "…去外面散散步看看风景")
    }
}
