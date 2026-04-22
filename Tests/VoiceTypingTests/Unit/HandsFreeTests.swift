import XCTest
@testable import VoiceTyping

/// v0.5.3 hands-free coverage. The interesting state machine lives on
/// `AppDelegate` (Fn↑ tap-vs-hold branch + silence/no-speech timers +
/// VAD watchdog). Constructing `AppDelegate` in a test requires the full
/// AppKit + audio + recognizer stack; that integration test belongs in
/// the E2E suite once we have a fixture-driven hotkey simulator (v0.5.4
/// test-infra work).
///
/// What this file pins:
///   - the three `HandsFree.*` decision values (so a careless edit can't
///     silently change UX without a test failure)
///   - `AppState.handsFreeEnabled` UserDefaults round-trip
///   - `AppState.handsFreeActive` runtime-only default (NOT persisted)
@MainActor
final class HandsFreeTests: XCTestCase {

    // MARK: - Decision constants

    /// 200 ms is the "tap vs hold" boundary. Lowering risks misclassifying
    /// slow taps as holds (no-op for the user); raising risks classifying
    /// short holds as taps (silently switches the user into hands-free).
    func testTapThreshold_Is200ms() {
        XCTAssertEqual(HandsFree.tapThreshold, 0.2, accuracy: 0.001)
    }

    /// 1.5 s reads as a "comfortable end-of-sentence pause". Tighter cuts
    /// people off mid-thought; looser feels laggy.
    func testPostSpeechSilence_Is1500ms() {
        XCTAssertEqual(HandsFree.postSpeechSilence, 1.5, accuracy: 0.001)
    }

    /// 10 s is the accidental-tap auto-cancel window. v0.5.3 design picked
    /// this over 5 s because users may glance at notes for 6-7 s before
    /// starting (5 s would cancel before they begin).
    func testNoSpeechTimeout_Is10s() {
        XCTAssertEqual(HandsFree.noSpeechTimeout, 10.0, accuracy: 0.001)
    }

    // MARK: - AppState handsFreeEnabled round-trip

    func testHandsFreeEnabled_DefaultsFalse() {
        let key = "handsFreeEnabled"
        let suite = freshDefaults()
        UserDefaults.standard.set(suite, forKey: key)  // ensure clean
        UserDefaults.standard.removeObject(forKey: key)

        let state = AppState()
        XCTAssertFalse(state.handsFreeEnabled,
                        "Hands-free is off by default for v0.5.3 (dogfood opt-in)")
    }

    func testHandsFreeEnabled_PersistsAcrossInit() {
        let key = "handsFreeEnabled"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let state = AppState()
        XCTAssertTrue(state.handsFreeEnabled,
                       "AppState init should restore the persisted toggle")
    }

    func testHandsFreeEnabled_SetterPersists() {
        let key = "handsFreeEnabled"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let state = AppState()
        XCTAssertFalse(state.handsFreeEnabled)
        state.handsFreeEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                       "didSet must write to UserDefaults for next-launch restore")
    }

    // MARK: - AppState handsFreeActive (runtime-only)

    func testHandsFreeActive_DefaultsFalse_NotPersisted() {
        // Even if a previous run left the runtime flag in some state, a
        // fresh AppState should boot with handsFreeActive=false. There is
        // no UserDefaults backing — confirm by setting + recreating.
        let state1 = AppState()
        XCTAssertFalse(state1.handsFreeActive)
        state1.handsFreeActive = true

        // No didSet on this property; second AppState must still be false.
        let state2 = AppState()
        XCTAssertFalse(state2.handsFreeActive,
                        "handsFreeActive is a transient UI flag, must not persist")
    }

    // MARK: - Helpers

    private func freshDefaults() -> Any { UUID().uuidString }
}
