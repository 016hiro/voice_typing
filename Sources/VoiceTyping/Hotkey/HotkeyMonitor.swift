import AppKit
import ApplicationServices
import CoreGraphics

public final class HotkeyMonitor: @unchecked Sendable {

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
    /// Internal so unit tests can simulate a held key when verifying
    /// `swap(to:)`'s synthesized-release contract without spinning up a real
    /// CGEventTap (which would need Accessibility permission).
    internal var pressed = false
    private var trigger: HotkeyTrigger
    private var promptedAccessibility = false

    public init(trigger: HotkeyTrigger = .default) {
        self.trigger = trigger
        let (stream, cont) = AsyncStream<Transition>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.events = stream
        self.continuation = cont
    }

    public var currentTrigger: HotkeyTrigger { trigger }

    deinit {
        stop()
    }

    public func start(promptIfNeeded: Bool = true) throws {
        guard Permissions.checkAccessibility(prompt: promptIfNeeded) else {
            throw MonitorError.accessibilityDenied
        }
        promptedAccessibility = true
        try startTap()
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
        Log.hotkey.info("Hotkey monitor stopped (\(self.trigger.rawValue, privacy: .public))")
    }

    /// Switch to a new trigger key on the fly. If the current trigger is being
    /// held when swap is called, a synthesized `.released` is yielded first so
    /// upstream state machines can clean up before the old tap is torn down.
    public func swap(to newTrigger: HotkeyTrigger) throws {
        if newTrigger == trigger { return }

        if pressed {
            pressed = false
            continuation.yield(.released)
        }

        let wasRunning = (eventTap != nil)
        stop()
        trigger = newTrigger

        if wasRunning {
            try startTap()
        }
        Log.hotkey.info("Hotkey monitor swapped to \(newTrigger.rawValue, privacy: .public)")
    }

    private func startTap() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: trigger.eventMask,
            callback: hotkeyTapCallback,
            userInfo: selfPtr
        ) else {
            throw MonitorError.tapCreationFailed
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("Hotkey monitor started (\(self.trigger.rawValue, privacy: .public))")
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

        switch trigger.detection {
        case .modifier:
            return handleModifier(type: type, event: event)
        case .functionKey:
            return handleFunctionKey(type: type, event: event)
        }
    }

    private func handleModifier(type: CGEventType, event: CGEvent) -> CGEvent? {
        guard type == .flagsChanged else { return event }

        switch trigger {
        case .fn:
            // Legacy detection: pure flag-bit. Robust on hardware that doesn't
            // surface keycode 63 in flagsChanged events.
            let isFn = event.flags.contains(.maskSecondaryFn)
            guard isFn != pressed else { return nil }
            pressed = isFn
            continuation.yield(isFn ? .pressed : .released)
            return nil

        case .rightOption, .rightCommand:
            // Disambiguate left vs right by keycode. The flag bit reflects
            // aggregate state across both sides, so we toggle pressed state on
            // every kc match — flagsChanged fires exactly once per physical
            // press / release for our key.
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == trigger.keycode else { return event }
            pressed.toggle()
            continuation.yield(pressed ? .pressed : .released)
            return nil

        default:
            return event
        }
    }

    private func handleFunctionKey(type: CGEventType, event: CGEvent) -> CGEvent? {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard kc == trigger.keycode else { return event }

        switch type {
        case .keyDown:
            // keyDown auto-repeats while held; only first transition counts.
            guard !pressed else { return nil }
            pressed = true
            continuation.yield(.pressed)
            return nil
        case .keyUp:
            guard pressed else { return nil }
            pressed = false
            continuation.yield(.released)
            return nil
        default:
            return event
        }
    }
}

private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if let passed = monitor.handle(type: type, event: event) {
        return Unmanaged.passUnretained(passed)
    }
    return nil
}
