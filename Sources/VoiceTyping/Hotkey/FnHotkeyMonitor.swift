import AppKit
import ApplicationServices
import CoreGraphics

public final class FnHotkeyMonitor: @unchecked Sendable {

    public enum Transition: Sendable {
        case pressed
        case released
    }

    public enum MonitorError: Error {
        case accessibilityDenied
        case tapCreationFailed
    }

    public let events: AsyncStream<Transition>
    private let continuation: AsyncStream<Transition>.Continuation

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    public init() {
        let (stream, cont) = AsyncStream<Transition>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.events = stream
        self.continuation = cont
    }

    deinit {
        stop()
    }

    public func start(promptIfNeeded: Bool = true) throws {
        guard Permissions.checkAccessibility(prompt: promptIfNeeded) else {
            throw MonitorError.accessibilityDenied
        }

        // NX_SYSDEFINED events (type 14) aren't represented as a CGEventType case in Swift,
        // so we only listen for flagsChanged. This is enough for Fn on built-in and most
        // external Apple keyboards — Fn toggles CGEventFlags.maskSecondaryFn in the flags.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnHotkeyTapCallback,
            userInfo: selfPtr
        ) else {
            throw MonitorError.tapCreationFailed
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("Fn hotkey monitor started")
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        Log.hotkey.info("Fn hotkey monitor stopped")
    }

    // MARK: - Called from the C callback

    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.hotkey.warning("Event tap re-enabled after \(String(describing: type), privacy: .public)")
            }
            return event
        }

        switch type {
        case .flagsChanged:
            let isFn = event.flags.contains(.maskSecondaryFn)
            if isFn != fnPressed {
                fnPressed = isFn
                continuation.yield(isFn ? .pressed : .released)
                // Swallow the Fn flag-change event so the OS doesn't trigger the
                // "press Fn to" action (emoji picker, dictation, etc.).
                return nil
            }
            return event

        default:
            return event
        }
    }
}

private let fnHotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<FnHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if let passed = monitor.handle(type: type, event: event) {
        return Unmanaged.passUnretained(passed)
    }
    return nil
}
