import XCTest
@testable import VoiceTyping

/// v0.6.4: keeps ASRKeepAlive's contract pinned. Whoever changes the cadence
/// or the silence buffer length here is on the hook for re-checking
/// `docs/todo/v0.6.4.md` §2 (cadence × CPU table) and the 400-sample FFT
/// minimum in `QwenASRRecognizer.transcribeSegmentSync`.
@MainActor
final class ASRKeepAliveTests: XCTestCase {

    // MARK: - Constants pinning

    func testDefaultInterval_Is90Seconds() {
        XCTAssertEqual(ASRKeepAlive.defaultInterval, 90,
                       "Cadence chosen to fit inside macOS compressor's 5-10 min decision window. " +
                       "Bumping past ~180 s loses reliability; below 60 s burns battery.")
    }

    func testDummySamples_Is200msAt16kHz() {
        XCTAssertEqual(ASRKeepAlive.dummySamples.count, 3200,
                       "200 ms × 16 kHz = 3200 samples")
    }

    func testDummySamples_ExceedsFFTWindow() {
        XCTAssertGreaterThanOrEqual(ASRKeepAlive.dummySamples.count, 400,
                                    "Below 400 samples QwenASR's transcribeSegmentSync short-circuits without touching weights")
    }

    func testDummySamples_AreAllSilent() {
        XCTAssertTrue(ASRKeepAlive.dummySamples.allSatisfy { $0 == 0 },
                      "Non-silent samples could trigger Hallucination filter / VAD oddities; " +
                      "we want a guaranteed-empty transcribe result")
    }

    // MARK: - tick() state-aware skip

    func testTick_FiresWhenStateIsReady() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.ready)
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.tick()
        ka.stop()
        XCTAssertEqual(fake.tickCount, 1)
    }

    func testTick_SkipsWhenStateIsUnloaded() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.unloaded)
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.tick()
        ka.stop()
        XCTAssertEqual(fake.tickCount, 0)
    }

    func testTick_SkipsWhenStateIsLoading() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.loading(progress: 0.5))
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.tick()
        ka.stop()
        XCTAssertEqual(fake.tickCount, 0)
    }

    func testTick_SkipsWhenStateIsFailed() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.failed(NSError(domain: "test", code: 1)))
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.tick()
        ka.stop()
        XCTAssertEqual(fake.tickCount, 0)
    }

    func testTick_NoOpWithoutStart() {
        let ka = ASRKeepAlive()
        ka.tick()  // no target ever set; must not crash
    }

    func testTick_NoOpAfterStop() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.ready)
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.stop()
        ka.tick()
        XCTAssertEqual(fake.tickCount, 0,
                       "stop() clears target so a stray tick can't drive a recognizer the AppDelegate is no longer tracking")
    }

    // MARK: - Tick payload

    func testTick_PassesSilentBufferAndNoContext() {
        let fake = FakeKeepAliveTarget()
        fake.setState(.ready)
        let ka = ASRKeepAlive()
        ka.start(target: fake)
        ka.tick()
        ka.stop()
        XCTAssertEqual(fake.lastSamples?.count, 3200)
        XCTAssertNil(fake.lastContext, "Keep-alive must not ride glossary biasing")
    }

    // MARK: - start() target replacement

    func testStart_ReplacesPreviousTarget() {
        let first = FakeKeepAliveTarget()
        first.setState(.ready)
        let second = FakeKeepAliveTarget()
        second.setState(.ready)
        let ka = ASRKeepAlive()
        ka.start(target: first)
        ka.start(target: second)
        ka.tick()
        ka.stop()
        XCTAssertEqual(first.tickCount, 0,
                       "First target should be detached when second start() lands — stale ticks would race a backend swap")
        XCTAssertEqual(second.tickCount, 1)
    }

    // MARK: - Timer lifecycle (integration — uses real Timer at fast cadence)

    func testTimer_FiresPeriodically() async throws {
        let fake = FakeKeepAliveTarget()
        fake.setState(.ready)
        let ka = ASRKeepAlive(interval: 0.1)
        ka.start(target: fake)
        // ~3 ticks worth of headroom; CI machines occasionally jitter so we
        // assert the lower bound, not an exact count.
        try await Task.sleep(nanoseconds: 350_000_000)
        ka.stop()
        XCTAssertGreaterThanOrEqual(fake.tickCount, 1,
                                    "Timer should fire at least once over a 350 ms wait at 100 ms interval")
    }

    func testTimer_StopsAfterStop() async throws {
        let fake = FakeKeepAliveTarget()
        fake.setState(.ready)
        let ka = ASRKeepAlive(interval: 0.1)
        ka.start(target: fake)
        try await Task.sleep(nanoseconds: 250_000_000)
        ka.stop()
        let countAtStop = fake.tickCount
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fake.tickCount, countAtStop,
                       "No more ticks should fire after stop()")
    }
}

// MARK: - Fake

/// Minimal `KeepAliveTarget` for tests. State and counters guarded by NSLock
/// because the real timer-driven tick fires from a background `Task.detached`.
private final class FakeKeepAliveTarget: KeepAliveTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: RecognizerState = .unloaded
    private var _tickCount = 0
    private var _lastSamples: [Float]?
    private var _lastLanguage: String?
    private var _lastContext: String?

    var state: RecognizerState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    func setState(_ s: RecognizerState) {
        lock.lock(); _state = s; lock.unlock()
    }

    var tickCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _tickCount
    }

    var lastSamples: [Float]? {
        lock.lock(); defer { lock.unlock() }
        return _lastSamples
    }

    var lastContext: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastContext
    }

    func transcribeSegmentSync(samples: [Float], language: String, context: String?) -> String {
        lock.lock()
        _tickCount += 1
        _lastSamples = samples
        _lastLanguage = language
        _lastContext = context
        lock.unlock()
        return ""
    }
}
