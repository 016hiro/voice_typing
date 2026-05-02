import XCTest
@testable import VoiceTyping

/// v0.7.1 dogfood follow-up: pins the watchdog's two contracts —
/// (1) fast bodies don't fire the timeout, (2) slow bodies do — and the
/// event payload carries enough context to correlate with capture data.
final class TranscribeWatchdogTests: XCTestCase {

    func testFastBody_DoesNotFireTimeout() throws {
        let fired = Locked(false)
        let result = TranscribeWatchdog.run(
            callsite: "test",
            samples: 16_000,
            language: "en",
            contextChars: 0,
            threshold: 0.2,
            onTimeout: { _ in fired.set(true) }
        ) {
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        // Body returned in <1 ms so the 200 ms timer should never fire.
        // Wait past the threshold to confirm the work item was cancelled.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(fired.get(), "Watchdog must not fire when body returns before threshold")
    }

    func testSlowBody_FiresTimeoutWithMatchingEvent() throws {
        let captured = Locked<TranscribeWatchdog.Event?>(nil)
        let result = TranscribeWatchdog.run(
            callsite: "stream-segment",
            samples: 32_000,
            language: "zh",
            contextChars: 36,
            threshold: 0.1,
            onTimeout: { event in captured.set(event) }
        ) {
            // Simulate a hung MLX dispatch by sleeping past the threshold.
            Thread.sleep(forTimeInterval: 0.3)
            return "delayed"
        }
        XCTAssertEqual(result, "delayed", "Watchdog must not interrupt — body always runs to completion")
        let event = captured.get()
        XCTAssertNotNil(event, "Watchdog must fire when body exceeds threshold")
        XCTAssertEqual(event?.callsite, "stream-segment")
        XCTAssertEqual(event?.samples, 32_000)
        XCTAssertEqual(event?.language, "zh")
        XCTAssertEqual(event?.contextChars, 36)
        XCTAssertEqual(event?.thresholdSec, 0.1)
    }

    func testDefaultThreshold_Is5Seconds() {
        XCTAssertEqual(TranscribeWatchdog.defaultThresholdSec, 5.0,
                       "Pinned to the threshold chosen against v0.6.1 p99 + cold-decompress headroom; " +
                       "lowering risks false positives, raising delays orphan-session detection.")
    }
}

/// Tiny mutex wrapper so the timeout closure (called on a global queue) can
/// safely report back to the test thread without `@unchecked Sendable` on
/// XCTestCase.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ new: T) {
        lock.lock(); defer { lock.unlock() }
        value = new
    }
}
