#!/usr/bin/env swift
// Spike #81 — verify keycode distinguishability for L/R modifier and function keys.
//
// Run: swift Scripts/spike_hotkey_keycode.swift
// Needs Accessibility permission for the parent terminal (iTerm/Terminal).
//
// Press these in order, watch the printout:
//   1. Left Option   (expected keycode 58)
//   2. Right Option  (expected keycode 61)
//   3. Left Command  (expected keycode 55)
//   4. Right Command (expected keycode 54)
//   5. Fn            (no keycode in flagsChanged on most builds; check flags has maskSecondaryFn)
//   6. F13           (expected keycode 105 on keyDown/keyUp)
//   7. F14           (expected keycode 107 on keyDown/keyUp)
// Ctrl-C to quit.

import AppKit
import CoreGraphics

let mask: CGEventMask =
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue)

let callback: CGEventTapCallBack = { _, type, event, _ in
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    let typeStr: String
    switch type {
    case .flagsChanged: typeStr = "flagsChanged"
    case .keyDown:      typeStr = "keyDown     "
    case .keyUp:        typeStr = "keyUp       "
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        FileHandle.standardError.write(Data("tap disabled, re-enabling\n".utf8))
        return Unmanaged.passUnretained(event)
    default:
        typeStr = "type=\(type.rawValue)"
    }
    let line = String(format: "%@  keycode=%-4d  flags=0x%016llx\n",
                      typeStr, keycode, flags)
    FileHandle.standardOutput.write(Data(line.utf8))
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: nil
) else {
    FileHandle.standardError.write(Data("failed to create event tap — grant Accessibility to your terminal\n".utf8))
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("listening… press the keys listed in the script header. Ctrl-C to quit.")
CFRunLoopRun()
