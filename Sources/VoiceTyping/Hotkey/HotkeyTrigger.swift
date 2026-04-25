import CoreGraphics
import Foundation

public enum HotkeyTrigger: String, CaseIterable, Sendable, Codable {
    case fn
    case rightOption
    case rightCommand
    case f13
    case f14

    public static let `default`: HotkeyTrigger = .fn

    public init(rawValueOrDefault raw: String?) {
        if let raw, let value = HotkeyTrigger(rawValue: raw) {
            self = value
        } else {
            self = .default
        }
    }

    public var displayName: String {
        switch self {
        case .fn:           return "Fn"
        case .rightOption:  return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .f13:          return "F13"
        case .f14:          return "F14"
        }
    }

    public var sideEffectNote: String {
        switch self {
        case .fn:
            return "macOS emoji picker / dictation shortcut on Fn will be disabled."
        case .rightOption:
            return "Right-Option character combos (e.g. ⌥e) will be disabled. Left Option still works."
        case .rightCommand:
            return "Right-Command system shortcuts will be disabled. Left Command still works."
        case .f13:
            return "Requires a keyboard with an F13 key. Use the indicator below to verify."
        case .f14:
            return "Requires a keyboard with an F14 key. Use the indicator below to verify."
        }
    }

    /// Whether this trigger is detected via `flagsChanged` (modifier keys) or
    /// `keyDown`/`keyUp` (function keys).
    public enum DetectionKind: Sendable {
        case modifier
        case functionKey
    }

    public var detection: DetectionKind {
        switch self {
        case .fn, .rightOption, .rightCommand: return .modifier
        case .f13, .f14: return .functionKey
        }
    }

    /// Verified keycodes (spike #81, 2026-04-26).
    public var keycode: Int64 {
        switch self {
        case .fn:           return 63
        case .rightOption:  return 61
        case .rightCommand: return 54
        case .f13:          return 105
        case .f14:          return 107
        }
    }

    /// Modifier flag bit that must be set in `event.flags` for `.modifier`
    /// triggers. Function keys return `nil` (no required flag).
    public var requiredFlag: CGEventFlags? {
        switch self {
        case .fn:           return .maskSecondaryFn
        case .rightOption:  return .maskAlternate
        case .rightCommand: return .maskCommand
        case .f13, .f14:    return nil
        }
    }

    /// Bitmask of `CGEventType` values this trigger needs to subscribe to.
    public var eventMask: CGEventMask {
        switch detection {
        case .modifier:
            return 1 << CGEventType.flagsChanged.rawValue
        case .functionKey:
            return (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)
        }
    }
}
