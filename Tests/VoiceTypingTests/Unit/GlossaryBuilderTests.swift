import XCTest
@testable import VoiceTyping

final class GlossaryBuilderTests: XCTestCase {

    // MARK: - buildQwenContext

    func testQwenContext_emptyDictionaryReturnsNil() {
        XCTAssertNil(GlossaryBuilder.buildQwenContext(from: [], language: .en))
    }

    func testQwenContext_englishIsCommaList() {
        let entries = [
            DictionaryEntry(term: "SwiftUI"),
            DictionaryEntry(term: "Combine")
        ]
        let ctx = GlossaryBuilder.buildQwenContext(from: entries, language: .en)
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("SwiftUI"))
        XCTAssertTrue(ctx!.contains("Combine"))
    }

    func testQwenContext_chineseUsesHotWordPrefix() {
        let entries = [
            DictionaryEntry(term: "动账"),
            DictionaryEntry(term: "沉降")
        ]
        let ctx = GlossaryBuilder.buildQwenContext(from: entries, language: .zhCN)
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.hasPrefix("热词"))
        XCTAssertTrue(ctx!.contains("动账"))
    }

    // MARK: - buildLLMGlossary

    func testLLMGlossary_splitsPreserveAndRewrite() {
        let entries = [
            DictionaryEntry(term: "SwiftUI"),
            DictionaryEntry(term: "Combine", pronunciationHints: ["com bine", "koom byne"])
        ]
        let out = GlossaryBuilder.buildLLMGlossary(from: entries)
        XCTAssertNotNil(out)
        // Term-only entry goes under "Preserve"; hinted entry under "Rewrite".
        XCTAssertTrue(out!.contains("Preserve"))
        XCTAssertTrue(out!.contains("- SwiftUI"))
        XCTAssertTrue(out!.contains("Rewrite"))
        XCTAssertTrue(out!.contains("com bine / koom byne → Combine"))
    }

    func testLLMGlossary_emptyReturnsNil() {
        XCTAssertNil(GlossaryBuilder.buildLLMGlossary(from: []))
    }

    // MARK: - matchedEntryIDs

    func testMatchedIDs_englishRequiresWordBoundary() {
        // "Python" should not match inside "Pythonic".
        let e = DictionaryEntry(term: "Python")
        let hits = GlossaryBuilder.matchedEntryIDs(
            in: "The Pythonic way forward",
            entries: [e]
        )
        XCTAssertTrue(hits.isEmpty, "word-boundary regex should reject substring")
    }

    func testMatchedIDs_englishCaseInsensitive() {
        let e = DictionaryEntry(term: "SwiftUI")
        let hits = GlossaryBuilder.matchedEntryIDs(
            in: "learning swiftui this week",
            entries: [e]
        )
        XCTAssertEqual(hits, [e.id])
    }

    func testMatchedIDs_cjkSubstringMatch() {
        // CJK has no word boundaries, so substring match is the only option.
        let e = DictionaryEntry(term: "配森")
        let hits = GlossaryBuilder.matchedEntryIDs(
            in: "超配森今天发布",
            entries: [e]
        )
        XCTAssertEqual(hits, [e.id])
    }

    func testMatchedIDs_hintAlsoCountsAsHit() {
        let e = DictionaryEntry(term: "Combine", pronunciationHints: ["com bine"])
        let hits = GlossaryBuilder.matchedEntryIDs(
            in: "use com bine to observe",
            entries: [e]
        )
        XCTAssertEqual(hits, [e.id])
    }

    // MARK: - LRU ordering under budget pressure

    func testGreedyFill_newestEntryWinsUnderTightBudget() {
        // Tight budget: only one of the two entries fits.
        let older = DictionaryEntry(
            term: "AlphaBetaGammaDelta",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = DictionaryEntry(
            term: "OmegaSigmaLambda",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        // Use English language (no 热词 prefix) and a tight budget. Both entries
        // cost ~7-8 tokens each; budget 8 fits newer but not both.
        let ctx = GlossaryBuilder.buildQwenContext(
            from: [older, newer],
            language: .en,
            budget: 8
        )
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("OmegaSigmaLambda"))
        XCTAssertFalse(ctx!.contains("AlphaBetaGammaDelta"))
    }
}
