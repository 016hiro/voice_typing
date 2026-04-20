#!/usr/bin/env bash
# Scripts/fetch_english_fixtures.sh — pull remote audio fixtures for ASR
# regression tests. Despite the name it fetches both English and Chinese now
# (name kept so docs / memory don't rot):
#   1. JFK inaugural clip from openai/whisper tests (PD, ~11 s)
#   2. LibriSpeech dev-clean subset → 7 short + 2 long English fixtures
#      (CC BY 4.0, downloads 322 MB tarball once to ~/.cache/vt-fixtures/)
#   3. FLEURS cmn_hans_cn dev subset → 5 Mandarin fixtures
#      (CC BY 4.0, downloads 207 MB tarball once)
#
# Usage: ./Scripts/fetch_english_fixtures.sh
#
# Safe to re-run — each stage skips what's already cached / already on disk.

set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl not found." >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg not found. Install with: brew install ffmpeg" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Tests/Fixtures"
mkdir -p "$OUT_DIR"

# -----------------------------------------------------------------------------
# Fixture 1: jfk_en_short — JFK "ask not what your country can do for you"
# Source: https://github.com/openai/whisper/blob/main/tests/jfk.flac
# License: Public domain (US federal government work, pre-1978).
# -----------------------------------------------------------------------------
JFK_URL="https://raw.githubusercontent.com/openai/whisper/main/tests/jfk.flac"
JFK_WAV="$OUT_DIR/jfk_en_short.wav"
JFK_META="$OUT_DIR/jfk_en_short.expected.json"

if [[ -f "$JFK_WAV" ]]; then
    echo "✓ jfk_en_short.wav already present — skipping download."
else
    echo "↓ Fetching JFK clip from openai/whisper..."
    TMP_FLAC="$(mktemp -t vt-jfk.XXXXXX.flac)"
    trap 'rm -f "$TMP_FLAC"' EXIT
    curl -fsSL -o "$TMP_FLAC" "$JFK_URL"

    echo "→ Converting to 16 kHz mono s16 WAV..."
    ffmpeg -loglevel error -y -i "$TMP_FLAC" \
        -ar 16000 -ac 1 -sample_fmt s16 \
        "$JFK_WAV"

    rm -f "$TMP_FLAC"
    trap - EXIT
    echo "  Wrote: $JFK_WAV"
fi

if [[ ! -f "$JFK_META" ]]; then
    # Keywords deliberately robust to VAD segmentation: "ask not" gets isolated
    # to a tiny utterance by Silero VAD and Qwen occasionally hallucinates on
    # 200ms bursts. "Americans" + "country" land in both batch and streaming
    # outputs reliably.
    cat > "$JFK_META" <<'EOF'
{
  "keywords": ["Americans", "country"],
  "minChars": 50,
  "maxChars": 300,
  "language": "en",
  "streamingMinPartials": 1
}
EOF
    echo "  Wrote: $JFK_META"
fi

# -----------------------------------------------------------------------------
# Attribution — document sources + licenses for committed fixtures.
# -----------------------------------------------------------------------------
ATTR="$OUT_DIR/ATTRIBUTION.md"
if [[ ! -f "$ATTR" ]]; then
    cat > "$ATTR" <<'EOF'
# Fixture attribution

## jfk_en_short.wav

- **Source**: `tests/jfk.flac` from [openai/whisper](https://github.com/openai/whisper/tree/main/tests)
- **Original content**: Excerpt from President John F. Kennedy's 1961 inaugural address — "And so my fellow Americans, ask not what your country can do for you..."
- **License**: Public Domain. US federal government works are not subject to copyright protection (17 U.S.C. § 105). This pre-1978 recording is in the public domain by default.
- **Processing**: Re-encoded from source FLAC to 16 kHz mono s16 WAV via `ffmpeg` (see `Scripts/fetch_english_fixtures.sh`).

## Self-recorded fixtures

Any `*.wav` not listed above was recorded by the repo maintainer via `Scripts/record_fixture.sh` and is their own copyrighted work, used here as a regression test fixture.
EOF
    echo "  Wrote: $ATTR"
fi

# -----------------------------------------------------------------------------
# LibriSpeech dev-clean — 7 short + 2 long (>60 s) fixtures via Python helper.
# Downloads + extracts the dataset once under ~/.cache/vt-fixtures/ (322 MB
# one-time), then the Python script picks diverse speakers and writes fixtures.
# -----------------------------------------------------------------------------
echo ""
echo "→ LibriSpeech dev-clean fixtures (7 short + 2 long)..."
python3 "$(dirname "$0")/fetch_librispeech_fixtures.py"

# -----------------------------------------------------------------------------
# FLEURS cmn_hans_cn — 5 Mandarin fixtures via Python helper.
# Downloads + extracts once to ~/.cache/vt-fixtures/ (~207 MB one-time).
# Used in place of user-recorded Chinese when the dev mic is noisy or unavailable.
# -----------------------------------------------------------------------------
echo ""
echo "→ FLEURS Mandarin fixtures (5 utterances, diverse durations + speakers)..."
python3 "$(dirname "$0")/fetch_fleurs_zh_fixtures.py"

echo ""
echo "Done. Fixtures in $OUT_DIR:"
ls -lh "$OUT_DIR"
