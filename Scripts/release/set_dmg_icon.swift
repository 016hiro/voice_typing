// set_dmg_icon.swift — set a file's Finder icon (the icon that shows when
// the file is viewed in Finder, distinct from a DMG's mounted-volume icon).
//
// Usage:  swift Scripts/release/set_dmg_icon.swift <icon.icns> <target-file>
//
// Why Swift: the AppKit / NSWorkspace.setIcon API is the only Apple-sanctioned
// path for this, and PyObjC isn't shipped with /usr/bin/python3. Swift is
// already in the toolchain, so no extra dep.
//
// Safe to re-run on the same target: setIcon writes to the file's resource
// fork (com.apple.ResourceFork xattr), not the data fork — Sparkle's EdDSA
// signature stays valid because sign_update reads the data fork only.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: set_dmg_icon <icon.icns> <target>\n".utf8))
    exit(2)
}

let iconPath = args[1]
let targetPath = args[2]

guard let icon = NSImage(contentsOfFile: iconPath) else {
    FileHandle.standardError.write(Data("error: failed to load icon \(iconPath)\n".utf8))
    exit(1)
}

let ok = NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: [])
if !ok {
    FileHandle.standardError.write(Data("error: setIcon returned false for \(targetPath)\n".utf8))
    exit(1)
}

print("icon set: \(targetPath) ← \(iconPath)")
