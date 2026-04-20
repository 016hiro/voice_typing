#!/usr/bin/env bash
# Scripts/record_fixture.sh — record a test fixture from your default microphone
# and write it to Tests/Fixtures/ at 16 kHz mono Float32 WAV.
#
# Usage:   ./Scripts/record_fixture.sh <name>
# Example: ./Scripts/record_fixture.sh mixed_zh_en
#
# Start recording: runs on Enter.
# Stop recording:  Ctrl+C (the WAV is finalised correctly).
#
# After it writes the WAV, you must create the matching expected.json with
# keywords, minChars, maxChars, language, streamingMinPartials. See
# Tests/Fixtures/README.md for the format.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <name>" >&2
    echo "  Name should be short and descriptive: e.g. 'mixed_zh_en', 'tech_terms_zh_short'" >&2
    exit 1
fi

NAME="$1"

if [[ ! "$NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "Error: name must be alphanumeric + underscores only (got: $NAME)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Tests/Fixtures"
OUT_WAV="$OUT_DIR/$NAME.wav"
OUT_META="$OUT_DIR/$NAME.expected.json"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

# Default audio input device on macOS is ":0" for avfoundation.
# List devices with: ffmpeg -f avfoundation -list_devices true -i ""
DEVICE="${VT_AUDIO_DEVICE:-:0}"

if [[ -f "$OUT_WAV" ]]; then
    read -r -p "Warning: $OUT_WAV already exists. Overwrite? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Aborted." >&2
        exit 1
    fi
fi

echo "Fixture name: $NAME"
echo "Output:       $OUT_WAV"
echo "Input device: $DEVICE   (override with VT_AUDIO_DEVICE)"
echo ""
echo "Speak your sample. Press Ctrl+C when done."
read -r -p "Press Enter to start recording..." _

# -f avfoundation: macOS input backend
# -i "$DEVICE":    ":0" = default audio input (no video)
# -ar 16000:       resample to 16 kHz
# -ac 1:           downmix to mono
# -sample_fmt s16: 16-bit signed PCM (loads fine into Float32 on our side,
#                  smaller file than f32le, plenty of headroom for speech)
# -y:              overwrite without prompt (we asked above)
#
# `|| true`: Ctrl+C finalises the WAV cleanly but ffmpeg exits non-zero
# (signal 2 → exit 255). `set -e` would abort the script before we can
# write the expected.json stub, so swallow the non-zero here. We verify
# the WAV exists below.
ffmpeg \
    -f avfoundation \
    -i "$DEVICE" \
    -ar 16000 \
    -ac 1 \
    -sample_fmt s16 \
    -y \
    "$OUT_WAV" || true

if [[ ! -f "$OUT_WAV" ]] || [[ ! -s "$OUT_WAV" ]]; then
    echo "Error: ffmpeg did not produce a usable WAV at $OUT_WAV" >&2
    exit 1
fi

echo ""
echo "Recorded: $OUT_WAV ($(ls -lh "$OUT_WAV" | awk '{print $5}'))"

if [[ ! -f "$OUT_META" ]]; then
    cat > "$OUT_META" <<EOF
{
  "keywords": ["EDIT_ME"],
  "minChars": 3,
  "maxChars": 200,
  "language": "zh-CN",
  "streamingMinPartials": 1
}
EOF
    echo "Wrote stub: $OUT_META"
    echo "  → Edit 'keywords' to 2-3 substrings you actually said (lowercase OK)"
    echo "  → Adjust 'language' to en / zh-CN / zh-TW / ja / ko as appropriate"
else
    echo "Metadata already present: $OUT_META (leaving untouched)"
fi

echo ""
echo "Next:"
echo "  1. Edit $OUT_META"
echo "  2. Verify locally:  make test-e2e"
echo "  3. Commit both files."
