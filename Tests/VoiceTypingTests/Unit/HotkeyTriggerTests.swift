import CoreGraphics
import XCTest
@testable import VoiceTyping

final class HotkeyTriggerTests: XCTestCase {

    func testDefaultIsFn() {
        XCTAssertEqual(HotkeyTrigger.default, .fn)
    }

    func testRawValueRoundTrip() {
        for trigger in HotkeyTrigger.allCases {
            let raw = trigger.rawValue
            XCTAssertEqual(HotkeyTrigger(rawValue: raw), trigger)
        }
    }

    func testInitWithMissingOrInvalidRawFallsBackToDefault() {
        XCTAssertEqual(HotkeyTrigger(rawValueOrDefault: nil), .fn)
        XCTAssertEqual(HotkeyTrigger(rawValueOrDefault: ""), .fn)
        XCTAssertEqual(HotkeyTrigger(rawValueOrDefault: "leftPinky"), .fn)
    }

    func testInitWithValidRawValuePicksTrigger() {
        XCTAssertEqual(HotkeyTrigger(rawValueOrDefault: "rightOption"), .rightOption)
        XCTAssertEqual(HotkeyTrigger(rawValueOrDefault: "f13"), .f13)
    }

    /// Keycodes verified on the dev machine via spike #81 (2026-04-26).
    func testKeycodesMatchSpikeResult() {
        XCTAssertEqual(HotkeyTrigger.fn.keycode,           63)
        XCTAssertEqual(HotkeyTrigger.rightOption.keycode,  61)
        XCTAssertEqual(HotkeyTrigger.rightCommand.keycode, 54)
        XCTAssertEqual(HotkeyTrigger.f13.keycode,         105)
        XCTAssertEqual(HotkeyTrigger.f14.keycode,         107)
    }

    func testDetectionKindSplitsModifierVsFunction() {
        XCTAssertEqual(HotkeyTrigger.fn.detection,           .modifier)
        XCTAssertEqual(HotkeyTrigger.rightOption.detection,  .modifier)
        XCTAssertEqual(HotkeyTrigger.rightCommand.detection, .modifier)
        XCTAssertEqual(HotkeyTrigger.f13.detection,          .functionKey)
        XCTAssertEqual(HotkeyTrigger.f14.detection,          .functionKey)
    }

    func testRequiredFlagPresentForModifiersOnly() {
        XCTAssertEqual(HotkeyTrigger.fn.requiredFlag,           .maskSecondaryFn)
        XCTAssertEqual(HotkeyTrigger.rightOption.requiredFlag,  .maskAlternate)
        XCTAssertEqual(HotkeyTrigger.rightCommand.requiredFlag, .maskCommand)
        XCTAssertNil(HotkeyTrigger.f13.requiredFlag)
        XCTAssertNil(HotkeyTrigger.f14.requiredFlag)
    }

    func testEventMaskCoversCorrectEventTypes() {
        let modMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        XCTAssertEqual(HotkeyTrigger.fn.eventMask,           modMask)
        XCTAssertEqual(HotkeyTrigger.rightOption.eventMask,  modMask)
        XCTAssertEqual(HotkeyTrigger.rightCommand.eventMask, modMask)

        let fnKeyMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        XCTAssertEqual(HotkeyTrigger.f13.eventMask, fnKeyMask)
        XCTAssertEqual(HotkeyTrigger.f14.eventMask, fnKeyMask)
    }

    func testDisplayNameAndSideEffectNoteAreNonEmpty() {
        for trigger in HotkeyTrigger.allCases {
            XCTAssertFalse(trigger.displayName.isEmpty, "\(trigger)")
            XCTAssertFalse(trigger.sideEffectNote.isEmpty, "\(trigger)")
        }
    }
}

final class HotkeyMonitorSwapTests: XCTestCase {

    func testSwapWhilePressedYieldsSynthesizedRelease() async throws {
        let monitor = HotkeyMonitor(trigger: .fn)
        // Simulate "user is currently holding Fn" without a real event tap.
        monitor.pressed = true

        try monitor.swap(to: .rightOption)

        // `swap` must emit `.released` so the AppDelegate state machine can
        // unwind the in-flight recording before the old tap is torn down.
        var iterator = monitor.events.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertEqual(next, .released)
        XCTAssertEqual(monitor.currentTrigger, .rightOption)
        XCTAssertFalse(monitor.pressed)
    }

    func testSwapWhenIdleDoesNotYield() async throws {
        let monitor = HotkeyMonitor(trigger: .fn)
        XCTAssertFalse(monitor.pressed)

        try monitor.swap(to: .f13)
        XCTAssertEqual(monitor.currentTrigger, .f13)

        // No event should have been yielded — verify by racing against a
        // short timeout.
        let yielded = await withTaskGroup(of: HotkeyMonitor.Transition?.self) { group in
            group.addTask {
                var it = monitor.events.makeAsyncIterator()
                return await it.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        XCTAssertNil(yielded)
    }

    func testSwapToSameTriggerIsNoOp() throws {
        let monitor = HotkeyMonitor(trigger: .fn)
        monitor.pressed = true

        try monitor.swap(to: .fn)
        // pressed should not be cleared, no events yielded.
        XCTAssertTrue(monitor.pressed)
        XCTAssertEqual(monitor.currentTrigger, .fn)
    }
}

extension HotkeyMonitor.Transition: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.pressed, .pressed), (.released, .released): return true
        default: return false
        }
    }
}
