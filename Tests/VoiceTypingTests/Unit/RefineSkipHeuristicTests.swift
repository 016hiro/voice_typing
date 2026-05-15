import XCTest
@testable import VoiceTyping

/// v0.8.0 #S1 — tests for the pre-LLM skip gate (Variant C rule + Layer 1
/// substring hotword guard + Layer 2 phonetic hotword guard).
///
/// The phonetic cases mirror the 8 hand-built fixtures documented in
/// `docs/todo/v0.8.0.md` and the data-driven design in the Python prototype
/// (`Scripts/analysis/hotword_phonetic_replay.py`). Each case is a hotword
/// mishearing that the rule heuristic would happily skip, with damage if
/// no guard catches it.
final class RefineSkipHeuristicTests: XCTestCase {

    // MARK: - Variant C rule heuristic

    func testRule_emptyInputPasses() {
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic(""))
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic("   \n  "))
    }

    func testRule_shortCleanTextPasses() {
        // Pick fixtures with NO adjacent 1- or 2-char repeats — the Chinese
        // stutter regex `(.{1,2})\1` is intentionally a wide net (catches
        // 嗯嗯, 这个 这个) and trips on English doubled letters too, so
        // "Hello" / "thanks" would all block. Document this here so test
        // authors don't reach for natural-looking English.
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic("好的"))
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic("OK"))
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic("yes"))
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic("bye now"))
    }

    func testRule_lengthBlocksSkip() {
        // Cycling alphabet so no `(.{1,2})\1` collision. 35 chars passes,
        // 45 fails purely on the 40-char length cap.
        let short = String(repeating: "abcde", count: 7)   // 35 chars
        let long = String(repeating: "abcde", count: 9)    // 45 chars
        XCTAssertTrue(RefineSkipHeuristic.passesRuleHeuristic(short))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic(long))
    }

    func testRule_zhFillersBlockSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("嗯好的"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("那个我觉得"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("就是说"))
    }

    func testRule_enFillersBlockSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("um well"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("you know it"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("basically yes"))
    }

    func testRule_stutterBlocksSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("这个 这个"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("the the cat"))
    }

    func testRule_zhNumberSequenceBlocksSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("一百二十三"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("三点一四"))
    }

    func testRule_unspacedCodeSwitchBlocksSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("使用Qwen"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("ABC好"))
    }

    func testRule_punctAdjacentASCIIBlocksSkip() {
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("test。"))
        XCTAssertFalse(RefineSkipHeuristic.passesRuleHeuristic("？next"))
    }

    // MARK: - Layer 1: substring hotword guard

    func testLayer1_substringTermMatchBlocksSkip() {
        let entries = [DictionaryEntry(term: "Qwen", pronunciationHints: ["千问"])]
        let decision = RefineSkipHeuristic.evaluate(input: "用 Qwen", entries: entries)
        // "用 Qwen" passes rule (code-switch is unspaced check; "用 Qwen" has a
        // space, so codeSwitchRegex won't match — rule passes; substring catches)
        XCTAssertEqual(decision.gate, .hotwordSubstring)
    }

    func testLayer1_substringHintMatchBlocksSkip() {
        // Mirrors the user's real dictionary: Claude Code with "Cloud Code"
        // hint. Input that the rule would skip (short, no rules) but contains
        // the hint verbatim.
        let entries = [DictionaryEntry(term: "Claude Code",
                                       pronunciationHints: ["Cloud Code"])]
        let decision = RefineSkipHeuristic.evaluate(input: "Cloud Code",
                                                    entries: entries)
        XCTAssertEqual(decision.gate, .hotwordSubstring)
    }

    func testLayer1_chineseHintSubstringBlocksSkip() {
        let entries = [DictionaryEntry(term: "e2e",
                                       pronunciationHints: ["一突一", "EtoE"])]
        let decision = RefineSkipHeuristic.evaluate(input: "一突一",
                                                    entries: entries)
        XCTAssertEqual(decision.gate, .hotwordSubstring)
    }

    // MARK: - Layer 2: phonetic guard

    /// The motivating case: ASR wrote "曲文" for "Qwen". User never enumerated
    /// "曲文" as a hint. Without Layer 2 the rule would skip and the user
    /// sees "曲文" injected.
    func testLayer2_quwenBlocksQwenSkip() {
        let entries = [DictionaryEntry(term: "Qwen")]
        let decision = RefineSkipHeuristic.evaluate(input: "曲文", entries: entries)
        XCTAssertEqual(decision.gate, .hotwordPhonetic)
        XCTAssertNotNil(decision.phoneticHit)
        XCTAssertEqual(decision.phoneticHit?.term, "Qwen")
    }

    func testLayer2_cloudcodeUnspacedBlocksClaudeCodeSkip() {
        let entries = [DictionaryEntry(term: "Claude Code")]
        let decision = RefineSkipHeuristic.evaluate(input: "cloudcode",
                                                    entries: entries)
        XCTAssertEqual(decision.gate, .hotwordPhonetic)
    }

    /// Negative: short clean text with no relation to any hotword should
    /// reach `.skipped`. Confirms the guard isn't over-eager.
    func testNegative_unrelatedShortChineseSkips() {
        let entries = [DictionaryEntry(term: "Qwen"),
                       DictionaryEntry(term: "Claude Code")]
        let decision = RefineSkipHeuristic.evaluate(input: "好的", entries: entries)
        XCTAssertEqual(decision.gate, .skipped)
    }

    func testNegative_unrelatedShortEnglishSkips() {
        let entries = [DictionaryEntry(term: "Qwen"),
                       DictionaryEntry(term: "Claude Code")]
        let decision = RefineSkipHeuristic.evaluate(input: "thanks much",
                                                    entries: entries)
        XCTAssertEqual(decision.gate, .skipped)
    }

    func testNegative_emptyDictAllowsSkipOnCleanInput() {
        let decision = RefineSkipHeuristic.evaluate(input: "thank you",
                                                    entries: [])
        XCTAssertEqual(decision.gate, .skipped)
    }

    // MARK: - PhoneticMatcher building blocks

    func testNormalizeForm_asciiLowercased() {
        XCTAssertEqual(PhoneticMatcher.normalizeForm("Qwen"), "qwen")
        XCTAssertEqual(PhoneticMatcher.normalizeForm("Claude Code"), "claudecode")
    }

    func testNormalizeForm_digitsKept() {
        XCTAssertEqual(PhoneticMatcher.normalizeForm("e2e"), "e2e")
        XCTAssertEqual(PhoneticMatcher.normalizeForm("k8s"), "k8s")
    }

    func testNormalizeForm_cjkToPinyin() {
        XCTAssertEqual(PhoneticMatcher.normalizeForm("你好"), "nihao")
        XCTAssertEqual(PhoneticMatcher.normalizeForm("曲文"), "quwen")
    }

    func testNormalizeForm_punctDropped() {
        XCTAssertEqual(PhoneticMatcher.normalizeForm("hello, world!"), "helloworld")
        XCTAssertEqual(PhoneticMatcher.normalizeForm("Qwen 3.5"), "qwen35")
    }

    func testLevenshtein_basics() {
        XCTAssertEqual(PhoneticMatcher.levenshtein("", ""), 0)
        XCTAssertEqual(PhoneticMatcher.levenshtein("abc", "abc"), 0)
        XCTAssertEqual(PhoneticMatcher.levenshtein("abc", ""), 3)
        XCTAssertEqual(PhoneticMatcher.levenshtein("", "abc"), 3)
        XCTAssertEqual(PhoneticMatcher.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(PhoneticMatcher.levenshtein("qwen", "quwen"), 1)
    }

    // MARK: - End-to-end gate ordering

    /// Rule firing pre-empts the hotword guards — refine runs regardless of
    /// hotword content. Verifies the layered evaluation order.
    func testRuleFiresEvenWithHotwordInInput() {
        let entries = [DictionaryEntry(term: "Qwen")]
        let decision = RefineSkipHeuristic.evaluate(
            input: "使用Qwen做测试", entries: entries)
        XCTAssertEqual(decision.gate, .rule)
    }
}
