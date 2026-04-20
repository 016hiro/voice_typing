import XCTest
@testable import VoiceTyping

final class HallucinationFilterTests: XCTestCase {

    // MARK: - Layer 1: training-data tail blacklist

    func testBlacklist_ZhTrainingTails_AllDropped() {
        let cases = [
            "谢谢观看",
            "谢谢观看。",        // trailing punctuation tolerated by normalize
            "谢谢观看！",
            "好的",
            "嗯",
            "对",
            "明镜与点点栏目",
        ]
        for c in cases {
            XCTAssertTrue(
                HallucinationFilter.isLikelyHallucination(segment: c, context: nil),
                "expected zh tail to be filtered: \(c)"
            )
        }
    }

    func testBlacklist_EnTrainingTails_AllDropped() {
        let cases = [
            "Thank you.",
            "Thanks for watching!",
            "Yeah.",
            "yeah",        // case-insensitive
            "OK.",
            "Mhm.",
            "♪",
            "(music)",
        ]
        for c in cases {
            XCTAssertTrue(
                HallucinationFilter.isLikelyHallucination(segment: c, context: nil),
                "expected en tail to be filtered: \(c)"
            )
        }
    }

    // Real speech that *contains* a blacklisted phrase but isn't the whole utterance
    // must survive — `"Thanks."` is a hallucination, `"Thanks for the help"` is not.
    func testBlacklist_SubstringNotFiltered() {
        let cases = [
            "Thanks for the help with the migration.",
            "Yeah, that's exactly what I meant.",
            "好的，我们就这么定了",
            "嗯，这个方案可以试试",
        ]
        for c in cases {
            XCTAssertFalse(
                HallucinationFilter.isLikelyHallucination(segment: c, context: nil),
                "real speech containing tail substring should NOT filter: \(c)"
            )
        }
    }

    // MARK: - Layer 2: prompt-echo detection

    func testEcho_ZhHotwordPrefix_AlwaysFiltered() {
        // Even with no context passed, `热词：` is a deterministic echo signal —
        // no human dictates a sentence that starts with "hotwords:".
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "热词：Rust、Python、Qwen3-ASR、VAD、E2E。",
            context: nil
        ))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "热词:Rust,Python",  // half-width colon variant
            context: nil
        ))
    }

    func testEcho_ZhExactMatchToContext_Filtered() {
        let ctx = "热词：Rust、Python、Qwen3-ASR、VAD、E2E。"
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "热词：Rust、Python、Qwen3-ASR、VAD、E2E。",
            context: ctx
        ))
    }

    func testEcho_EnBareCommaListMatchingContext_Filtered() {
        // Non-zh language uses bare comma list (per GlossaryBuilder.buildQwenContext).
        let ctx = "Rust, Python, Qwen3-ASR, VAD, E2E"
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "Rust, Python, Qwen3-ASR, VAD, E2E",
            context: ctx
        ))
        // Slight punctuation variation should still match (normalized).
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "Rust, Python, Qwen3-ASR, VAD, E2E.",
            context: ctx
        ))
    }

    func testEcho_PartialPrefixOfContext_Filtered() {
        // Qwen sometimes truncates the echo at maxTokens — only the first
        // few terms come through. We still want to drop it.
        let ctx = "热词：Rust、Python、Qwen3-ASR、VAD、E2E、SwiftUI、AppKit、TIS。"
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "热词：Rust、Python、Qwen3-ASR",
            context: ctx
        ))
    }

    // MARK: - Layer 2: false-positive guards

    func testEcho_RealSpeechContainingTerms_NotFiltered() {
        // User actually says a sentence that includes some dictionary terms.
        // Segment is short, ctx is long → segment is NOT a substring of ctx,
        // and ctx is NOT a substring of segment, so substring test fails → keep.
        let ctx = "热词：Rust、Python、Qwen3-ASR、VAD、E2E、SwiftUI。"
        let cases = [
            "我用 Rust 写了一个小工具",
            "Python 这个生态很成熟",
            "刚才那段是 VAD 切错了",
        ]
        for c in cases {
            XCTAssertFalse(
                HallucinationFilter.isLikelyHallucination(segment: c, context: ctx),
                "real speech with dict terms should NOT filter: \(c)"
            )
        }
    }

    func testEcho_ShortContextGuard_NoFalsePositive() {
        // 1-term dictionary normalized to <12 chars → Layer 2 disabled.
        // Without the guard, every segment containing "Linus" would test true.
        let ctx = "Linus"
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            segment: "Linus is on stage tomorrow.",
            context: ctx
        ))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            segment: "Linus",   // even if segment IS the whole ctx, short-ctx guard wins
            context: ctx
        ))
    }

    func testEcho_NilContext_OnlyLayer1Runs() {
        // No context → Layer 2 skipped entirely. Tails still filtered, real
        // speech still preserved.
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            segment: "Thank you.",
            context: nil
        ))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            segment: "Rust, Python, JavaScript",
            context: nil
        ))
    }

    func testEcho_EmptySegment_NotFiltered() {
        // Empty/whitespace-only segments aren't filtered (the runner already
        // skips them before calling here, but defensive).
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(segment: "", context: nil))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(segment: "   ", context: nil))
    }
}
