import XCTest
@testable import VoiceTyping

/// `RecordingPolicy.maxDuration` is the single source of truth for the
/// recording cap. v0.5.3 introduced it to remove the inline `useLive ? 600 :
/// 60` decision from `AppDelegate.startRecording` and to let the new
/// hands-free path derive its cap from the same logic.
///
/// These tests pin the timing × backend matrix so a careless edit to the
/// policy can't silently change the cap.
final class RecordingPolicyTests: XCTestCase {

    // MARK: - Live + Qwen → 600 s

    func testLive_QwenSmall_Returns600() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .live, backend: .qwenASR06B), 600)
    }

    func testLive_QwenLarge_Returns600() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .live, backend: .qwenASR17B), 600)
    }

    // MARK: - Live + non-Qwen → 60 s (defensive guard)

    /// Live mode is gated to Qwen at the call site (Whisper has no streaming
    /// path), but the policy double-guards. If the gate ever leaks, we want
    /// the cap to fall back to the conservative 60 s rather than allow
    /// 10-minute Whisper batch transcribes.
    func testLive_Whisper_Returns60_DefensiveGuard() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .live, backend: .whisperLargeV3), 60)
    }

    // MARK: - One-shot → 60 s (all backends)

    func testOneshot_QwenSmall_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .oneshot, backend: .qwenASR06B), 60)
    }

    func testOneshot_QwenLarge_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .oneshot, backend: .qwenASR17B), 60)
    }

    func testOneshot_Whisper_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .oneshot, backend: .whisperLargeV3), 60)
    }

    // MARK: - Post-record streaming → 60 s (all backends)

    /// Post-record streaming is VAD-segmented batch; the user still records
    /// the whole utterance in one shot, just with progressive reveal during
    /// transcription. Same risk profile as one-shot → same 60 s cap.
    func testPostrecord_QwenSmall_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .postrecord, backend: .qwenASR06B), 60)
    }

    func testPostrecord_QwenLarge_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .postrecord, backend: .qwenASR17B), 60)
    }

    func testPostrecord_Whisper_Returns60() {
        XCTAssertEqual(RecordingPolicy.maxDuration(timing: .postrecord, backend: .whisperLargeV3), 60)
    }

    // MARK: - Matrix completeness sanity

    /// Reminder: every (timing, backend) combo this enum can produce is
    /// covered above. If you add a TranscriptionTiming case or an ASRBackend
    /// case, add the corresponding tests — and probably an explicit policy
    /// branch in `RecordingPolicy.maxDuration`.
    func testMatrixIsExhaustive() {
        let timings = AppState.TranscriptionTiming.allCases
        let backends = ASRBackend.allCases
        XCTAssertEqual(timings.count, 3, "Add tests when TranscriptionTiming gains a case")
        XCTAssertEqual(backends.count, 3, "Add tests when ASRBackend gains a case")
    }
}
