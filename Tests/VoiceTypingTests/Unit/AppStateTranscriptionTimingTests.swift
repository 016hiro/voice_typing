import XCTest
@testable import VoiceTyping

/// Covers the v0.5.2 `AppState.transcriptionTiming` computed property: three
/// modes round-trip through the two underlying bool flags without dropping or
/// leaking state. Documented invariant — `live` takes precedence over
/// `postrecord` so that flipping `live` on never leaves the user in a
/// "both set" silent state, and switching away zeroes the other flag.
///
/// Tests touch `UserDefaults.standard` as a side effect (setters write
/// through). setUp/tearDown snapshot + restore the two keys so the dev's live
/// prefs aren't disturbed if these run in the host process.
@MainActor
final class AppStateTranscriptionTimingTests: XCTestCase {

    private let streamingKey = "streamingEnabled"
    private let liveKey = "liveStreamingEnabled"
    private var savedStreaming: Any?
    private var savedLive: Any?

    override func setUp() async throws {
        let ud = UserDefaults.standard
        savedStreaming = ud.object(forKey: streamingKey)
        savedLive = ud.object(forKey: liveKey)
        ud.removeObject(forKey: streamingKey)
        ud.removeObject(forKey: liveKey)
    }

    override func tearDown() async throws {
        let ud = UserDefaults.standard
        restore(key: streamingKey, value: savedStreaming)
        restore(key: liveKey, value: savedLive)
        _ = ud.synchronize()
    }

    private func restore(key: String, value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Getter: bool pair → timing

    func testGetter_BothFalse_IsOneshot() {
        let state = AppState()
        state.streamingEnabled = false
        state.liveStreamingEnabled = false
        XCTAssertEqual(state.transcriptionTiming, .oneshot)
    }

    func testGetter_StreamingOnly_IsPostrecord() {
        let state = AppState()
        state.streamingEnabled = true
        state.liveStreamingEnabled = false
        XCTAssertEqual(state.transcriptionTiming, .postrecord)
    }

    func testGetter_LiveOnly_IsLive() {
        let state = AppState()
        state.streamingEnabled = false
        state.liveStreamingEnabled = true
        XCTAssertEqual(state.transcriptionTiming, .live)
    }

    /// Legacy state where both flags ended up true (older `defaults write`
    /// sessions). The invariant is live wins — the getter must not surprise
    /// the user by returning `postrecord` from a mixed state.
    func testGetter_BothTrue_LiveWins() {
        let state = AppState()
        state.streamingEnabled = true
        state.liveStreamingEnabled = true
        XCTAssertEqual(state.transcriptionTiming, .live)
    }

    // MARK: - Setter: timing → bool pair

    func testSetter_Oneshot_ClearsBoth() {
        let state = AppState()
        state.streamingEnabled = true
        state.liveStreamingEnabled = true
        state.transcriptionTiming = .oneshot
        XCTAssertFalse(state.streamingEnabled)
        XCTAssertFalse(state.liveStreamingEnabled)
    }

    func testSetter_Postrecord_SetsStreamingOnly() {
        let state = AppState()
        state.streamingEnabled = false
        state.liveStreamingEnabled = true
        state.transcriptionTiming = .postrecord
        XCTAssertTrue(state.streamingEnabled)
        XCTAssertFalse(state.liveStreamingEnabled)
    }

    func testSetter_Live_SetsLiveOnly() {
        let state = AppState()
        state.streamingEnabled = true
        state.liveStreamingEnabled = false
        state.transcriptionTiming = .live
        XCTAssertFalse(state.streamingEnabled)
        XCTAssertTrue(state.liveStreamingEnabled)
    }

    // MARK: - Transitions

    /// User path that motivated the v0.5.2 rewrite: people switching from live
    /// back to post-record used to keep both bools true (dual-toggle UI).
    /// Picker setter must zero `live` so the runtime doesn't silently take
    /// the higher-precedence path.
    func testTransition_LiveToPostrecord_ClearsLive() {
        let state = AppState()
        state.transcriptionTiming = .live
        state.transcriptionTiming = .postrecord
        XCTAssertTrue(state.streamingEnabled)
        XCTAssertFalse(state.liveStreamingEnabled)
        XCTAssertEqual(state.transcriptionTiming, .postrecord)
    }

    func testTransition_PostrecordToLive_ClearsStreaming() {
        let state = AppState()
        state.transcriptionTiming = .postrecord
        state.transcriptionTiming = .live
        XCTAssertFalse(state.streamingEnabled)
        XCTAssertTrue(state.liveStreamingEnabled)
        XCTAssertEqual(state.transcriptionTiming, .live)
    }
}
