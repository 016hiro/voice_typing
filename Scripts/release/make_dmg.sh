#!/bin/bash
# make_dmg.sh — produce build/VoiceTyping-<VERSION>.dmg from build/VoiceTyping.app
#
# Usage:  ./Scripts/release/make_dmg.sh <VERSION>
# Output: build/VoiceTyping-<VERSION>.dmg
#
# Uses create-dmg (Homebrew) for window layout + custom volume icon.
# Without it the DMG opens with default Finder layout (icons cramped
# top-left, no volume icon → generic page-with-arrow icon).

set -euo pipefail

VERSION="${1:?Usage: make_dmg.sh <VERSION> (e.g. 0.6.0)}"
APP="build/VoiceTyping.app"
DMG="build/VoiceTyping-${VERSION}.dmg"
VOLICON="Resources/AppIcon.icns"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found. Run 'make build' first." >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not installed. Run 'make setup-dmg-tools' (or 'brew install create-dmg')." >&2
    exit 1
fi

rm -f "$DMG"

# Layout decisions:
#   600×400 window — fits comfortably without dwarfing icons
#   icon size 128 — large enough to invite the drag, small enough not to clip
#   VoiceTyping at (160, 200) / Applications at (440, 200) — symmetric drag path
#   --hide-extension hides ".app" since the icon already telegraphs it's an app
#   --no-internet-enable opts out of legacy MacOS quarantine flag mutations
create-dmg \
    --volname "VoiceTyping ${VERSION}" \
    --volicon "$VOLICON" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "VoiceTyping.app" 160 200 \
    --app-drop-link 440 200 \
    --hide-extension "VoiceTyping.app" \
    --no-internet-enable \
    "$DMG" \
    "$APP"

# create-dmg's --volicon sets the icon shown when the DMG is mounted (the
# volume icon), but NOT the icon shown for the .dmg file itself in Finder.
# The latter requires writing the icon into the file's resource fork via
# NSWorkspace.setIcon. Does not affect the data fork → EdDSA signature stays
# valid when sign_update runs after this step.
swift Scripts/release/set_dmg_icon.swift "$VOLICON" "$DMG"

size=$(stat -f%z "$DMG")
echo "built: $DMG (${size} bytes)"
