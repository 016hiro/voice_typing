#!/bin/bash
# make_dmg.sh — produce build/VoiceTyping-<VERSION>.dmg from build/VoiceTyping.app
#
# Usage:  ./Scripts/release/make_dmg.sh <VERSION>
# Output: build/VoiceTyping-<VERSION>.dmg

set -euo pipefail

VERSION="${1:?Usage: make_dmg.sh <VERSION> (e.g. 0.6.0)}"
APP="build/VoiceTyping.app"
DMG="build/VoiceTyping-${VERSION}.dmg"
STAGING="build/dmg-staging"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found. Run 'make build' first." >&2
    exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

# Payload: the app bundle + an Applications alias so the user can drag from
# DMG to /Applications without leaving the mounted volume.
cp -R "$APP" "$STAGING/VoiceTyping.app"
ln -s /Applications "$STAGING/Applications"

# UDZO = compressed read-only; standard for distribution DMGs.
# -volname is what the user sees when the DMG is mounted.
hdiutil create \
    -volname "VoiceTyping ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" > /dev/null

rm -rf "$STAGING"

size=$(stat -f%z "$DMG")
echo "built: $DMG (${size} bytes)"
