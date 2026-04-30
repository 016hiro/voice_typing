import XCTest
@testable import VoiceTyping

/// Unit tests for the SSE line parser. Covers:
/// - SSE comments (heartbeats) → skip
/// - Empty / unrecognized lines → skip (forward compat with `event:` etc.)
/// - `data: [DONE]` terminator
/// - Standard `data: {...}` content delta
/// - Mid-stream `{"error": {...}}` payload
/// - `delta.reasoning` (no `delta.content`) is dropped — we asked for exclude
final class SSEParserTests: XCTestCase {

    // MARK: - Skip cases

    func testEmpty_Skips() {
        XCTAssertEqual(SSEParser.parse(line: ""), .skip)
    }

    func testSSEComment_OpenRouterHeartbeat_Skips() {
        XCTAssertEqual(SSEParser.parse(line: ": OPENROUTER PROCESSING"), .skip)
    }

    func testSSEComment_Generic_Skips() {
        XCTAssertEqual(SSEParser.parse(line: ": keep-alive"), .skip)
    }

    func testEventLine_NoDataPrefix_Skips() {
        // Forward compat — some providers prepend `event:` lines.
        XCTAssertEqual(SSEParser.parse(line: "event: completion"), .skip)
    }

    func testGarbageLine_Skips() {
        XCTAssertEqual(SSEParser.parse(line: "<html><body>503</body></html>"), .skip)
    }

    func testDataPrefix_NotJSON_Skips() {
        // Defensive: provider sends a non-JSON `data:` payload that isn't [DONE].
        // Don't crash; just skip.
        XCTAssertEqual(SSEParser.parse(line: "data: not-json-at-all"), .skip)
    }

    // MARK: - Terminator

    func testDoneTerminator_ReturnsDone() {
        XCTAssertEqual(SSEParser.parse(line: "data: [DONE]"), .done)
    }

    // MARK: - Content delta

    func testContentDelta_SingleChunk_ReturnsContent() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .content("Hello"))
    }

    func testContentDelta_WithUnicode_PreservesCodepoints() {
        let line = #"data: {"choices":[{"delta":{"content":"你好 — α"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .content("你好 — α"))
    }

    func testContentDelta_EmptyContent_ReturnsEmptyString() {
        // OpenAI emits `{"delta":{"role":"assistant"}}` as the first event
        // (no content) before content starts streaming. Our parser returns
        // .skip for that case (no `content` field), but if a provider
        // emits an explicitly-empty content string we should pass it through.
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .content(""))
    }

    func testContentDelta_RoleOnlyFirstFrame_Skips() {
        // First SSE frame from OpenAI typically carries role but no content.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .skip)
    }

    func testContentDelta_ReasoningOnly_Skips() {
        // Reasoning-token-emitting models stream `delta.reasoning` separately
        // from `delta.content`. We asked for `reasoning.exclude=true`, but be
        // defensive — drop reasoning frames cleanly even if they arrive.
        let line = #"data: {"choices":[{"delta":{"reasoning":"Let me think..."}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .skip)
    }

    // MARK: - Mid-stream errors

    func testMidStreamError_MessageField_ReturnsError() {
        let line = #"data: {"error":{"code":429,"message":"Rate limit exceeded"}}"#
        XCTAssertEqual(SSEParser.parse(line: line), .error("Rate limit exceeded"))
    }

    func testMidStreamError_NoMessageField_ReturnsErrorWithDescription() {
        // Some providers send malformed errors. Don't drop the signal — wrap
        // whatever we got so the user sees something actionable.
        let line = #"data: {"error":{"code":500}}"#
        if case .error(let msg) = SSEParser.parse(line: line) {
            XCTAssertTrue(msg.contains("500"), "Expected error description to include code, got: \(msg)")
        } else {
            XCTFail("Expected .error event, got something else")
        }
    }
}

/// Tests for the model-aware timeout heuristic. The function is a substring
/// matcher so we exercise both the positive matches (each reasoning marker)
/// and a representative negative case.
final class CloudRefinerTimeoutHeuristicTests: XCTestCase {

    func testNonReasoning_GPT4oMini_Returns60() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "openai/gpt-4o-mini"), 60)
    }

    func testNonReasoning_Claude35Sonnet_Returns60() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "anthropic/claude-3.5-sonnet"), 60)
    }

    func testReasoning_O1Mini_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "openai/o1-mini"), 90)
    }

    func testReasoning_O3Mini_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "openai/o3-mini"), 90)
    }

    func testReasoning_DeepSeekR1_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "deepseek/deepseek-r1"), 90)
    }

    func testReasoning_ClaudeThinking_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "anthropic/claude-3.7-sonnet:thinking"), 90)
    }

    func testReasoning_GPT5_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "openai/gpt-5"), 90)
    }

    func testReasoning_QwQ_Returns90() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "qwen/qwq-32b"), 90)
    }

    func testCaseInsensitive_UpperCase_StillMatches() {
        XCTAssertEqual(CloudLLMRefiner.recommendedTimeout(for: "DeepSeek/DeepSeek-R1"), 90)
    }
}

/// Tests for the HTTP error label mapping. Verifies that documented
/// OpenRouter / API error codes get a human-readable prefix instead of
/// surfacing the raw `NSURLErrorTimedOut` description.
final class CloudRefinerErrorLabelTests: XCTestCase {

    func testEdgeTimeout_408_HasReadableLabel() {
        let s = CloudLLMRefiner.errorLabel(forStatus: 408, body: "{}")
        XCTAssertTrue(s.lowercased().contains("api edge"), "Expected 'API edge' in label, got: \(s)")
    }

    func testRateLimited_429_HasReadableLabel() {
        let s = CloudLLMRefiner.errorLabel(forStatus: 429, body: "{}")
        XCTAssertTrue(s.lowercased().contains("rate"), "Expected 'rate' in label, got: \(s)")
    }

    func testUpstreamTimeout_524_HasReadableLabel() {
        let s = CloudLLMRefiner.errorLabel(forStatus: 524, body: "{}")
        XCTAssertTrue(s.lowercased().contains("upstream"), "Expected 'upstream' in label, got: \(s)")
    }

    func testUpstreamOverloaded_529_HasReadableLabel() {
        let s = CloudLLMRefiner.errorLabel(forStatus: 529, body: "{}")
        XCTAssertTrue(s.lowercased().contains("overloaded"), "Expected 'overloaded' in label, got: \(s)")
    }

    func testGenericStatus_FallsBackToHTTPCode() {
        let s = CloudLLMRefiner.errorLabel(forStatus: 503, body: "Service Unavailable")
        XCTAssertTrue(s.contains("HTTP 503"), "Expected 'HTTP 503' in label, got: \(s)")
    }

    func testBodyTruncation_LongBody_CapsAt300() {
        let longBody = String(repeating: "x", count: 1000)
        let s = CloudLLMRefiner.errorLabel(forStatus: 500, body: longBody)
        // Prefix is "HTTP 500: " (10 chars) + at most 300 of body = 310.
        XCTAssertLessThanOrEqual(s.count, 310)
    }
}
