#!/usr/bin/env python3
"""
Extract regression-test fixtures from LibriSpeech dev-clean.

LibriSpeech is CC BY 4.0 (on top of public-domain LibriVox recordings), which
lets us redistribute individual clips in this repo with attribution.

Strategy:
  * 7 short fixtures — diverse speakers, ~5-12 s each. Picked as the first
    qualifying utterance from 7 different (speaker, chapter) directories.
  * 2 long  fixtures — >60 s each, obtained by concatenating all consecutive
    utterances in a single chapter until the duration threshold is met.

Keywords for expected.json are lifted straight from the official trans.txt
transcript — two of the longest content words (≥5 letters, non-stopword).

Run via `Scripts/fetch_english_fixtures.sh`, not directly.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Optional

CACHE_DIR = Path.home() / ".cache" / "vt-fixtures"
TARBALL = CACHE_DIR / "LibriSpeech-dev-clean.tar.gz"
EXTRACT_ROOT = CACHE_DIR / "LibriSpeech"
DEV_CLEAN = EXTRACT_ROOT / "dev-clean"
TARBALL_URL = "https://www.openslr.org/resources/12/dev-clean.tar.gz"

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = REPO_ROOT / "Tests" / "Fixtures"
ATTRIBUTION = FIXTURES_DIR / "ATTRIBUTION.md"

# English stopwords we exclude from keyword picking. Short list — just the
# common articles / pronouns / auxiliaries that dominate most transcripts.
STOPWORDS = {
    "about", "after", "again", "also", "been", "before", "being", "could",
    "every", "from", "have", "having", "here", "into", "more", "most", "must",
    "never", "only", "other", "should", "some", "such", "than", "that",
    "their", "them", "then", "there", "these", "they", "this", "those",
    "through", "under", "very", "were", "what", "when", "where", "which",
    "while", "with", "would", "your", "yours", "said", "shall", "still",
    "upon", "unto", "much", "many",
}


def log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def ensure_tarball() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if TARBALL.exists() and TARBALL.stat().st_size > 300_000_000:
        log(f"✓ LibriSpeech tarball already cached: {TARBALL}")
        return
    log(f"↓ Downloading LibriSpeech dev-clean (~322 MB) to {TARBALL}")
    log("  (one-time; cached for all future runs)")
    subprocess.run(
        ["curl", "-fL", "--progress-bar", "-o", str(TARBALL), TARBALL_URL],
        check=True,
    )


def ensure_extracted() -> None:
    if DEV_CLEAN.exists() and any(DEV_CLEAN.iterdir()):
        log(f"✓ Already extracted at {DEV_CLEAN}")
        return
    log(f"→ Extracting to {EXTRACT_ROOT}")
    EXTRACT_ROOT.mkdir(parents=True, exist_ok=True)
    with tarfile.open(TARBALL, "r:gz") as tar:
        tar.extractall(path=EXTRACT_ROOT.parent)


def flac_duration(path: Path) -> float:
    """Duration in seconds, via ffprobe."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        check=True, capture_output=True, text=True,
    )
    return float(out.stdout.strip())


def parse_trans(trans_path: Path) -> dict[str, str]:
    """Parse a LibriSpeech `<spk>-<chap>.trans.txt` — `utt_id TEXT` per line."""
    mapping: dict[str, str] = {}
    for line in trans_path.read_text().splitlines():
        if not line.strip():
            continue
        utt_id, _, text = line.partition(" ")
        mapping[utt_id] = text.strip()
    return mapping


def pick_keywords(transcript: str, count: int = 2) -> list[str]:
    """Pick `count` distinctive words from the transcript for keyword match."""
    words = re.findall(r"[A-Za-z]+", transcript.lower())
    content = [w for w in words if len(w) >= 5 and w not in STOPWORDS]
    # Order by length descending, break ties by first-appearance.
    content_sorted = sorted(set(content), key=lambda w: (-len(w), words.index(w)))
    return content_sorted[:count]


def convert_flac_to_wav(flac: Path, wav: Path) -> None:
    """FLAC → 16 kHz mono s16 WAV. Overwrites existing."""
    wav.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(flac),
         "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(wav)],
        check=True,
    )


def concat_flacs_to_wav(flacs: list[Path], wav: Path) -> None:
    """Concatenate multiple FLACs into one 16 kHz mono s16 WAV via ffmpeg's
    concat demuxer (needs identical codec / sample rate, which LibriSpeech
    chapters satisfy — same speaker, same session)."""
    wav.parent.mkdir(parents=True, exist_ok=True)
    # Build concat list file
    list_path = CACHE_DIR / f"_concat_{wav.stem}.txt"
    list_path.write_text("".join(f"file '{f}'\n" for f in flacs))
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
         "-i", str(list_path), "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
         str(wav)],
        check=True,
    )
    list_path.unlink(missing_ok=True)


def discover_chapters() -> list[tuple[Path, Path, dict[str, str]]]:
    """Yield (chapter_dir, trans_path, transcripts) for every chapter in dev-clean."""
    results = []
    for spk_dir in sorted(DEV_CLEAN.iterdir()):
        if not spk_dir.is_dir():
            continue
        for chap_dir in sorted(spk_dir.iterdir()):
            if not chap_dir.is_dir():
                continue
            trans_files = list(chap_dir.glob("*.trans.txt"))
            if not trans_files:
                continue
            trans = parse_trans(trans_files[0])
            results.append((chap_dir, trans_files[0], trans))
    return results


def write_meta(meta_path: Path, keywords: list[str], transcript: str,
               streaming_min: int = 1) -> None:
    min_chars = max(20, int(len(transcript) * 0.3))
    max_chars = int(len(transcript) * 3) + 100
    meta = {
        "keywords": keywords,
        "minChars": min_chars,
        "maxChars": max_chars,
        "language": "en",
        "streamingMinPartials": streaming_min,
    }
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")


def make_short_fixture(chapter_dir: Path, transcripts: dict[str, str],
                       out_name: str) -> Optional[str]:
    """Pick the first utterance in a chapter that's 5-12 s; emit WAV + expected.json.
    Returns the transcript text on success (for attribution)."""
    flacs = sorted(chapter_dir.glob("*.flac"))
    for flac in flacs:
        dur = flac_duration(flac)
        if not (5.0 <= dur <= 12.0):
            continue
        utt_id = flac.stem
        text = transcripts.get(utt_id)
        if not text:
            continue
        keywords = pick_keywords(text, count=2)
        if len(keywords) < 2:
            continue

        wav = FIXTURES_DIR / f"{out_name}.wav"
        meta = FIXTURES_DIR / f"{out_name}.expected.json"
        convert_flac_to_wav(flac, wav)
        write_meta(meta, keywords, text)
        log(f"✓ {out_name}.wav ({dur:.1f}s) — {utt_id}: {text[:60]}...")
        return f"{out_name}: LibriSpeech dev-clean {utt_id}"
    return None


def make_long_fixture(chapter_dir: Path, transcripts: dict[str, str],
                      out_name: str, target_duration: float) -> Optional[str]:
    """Concatenate consecutive utterances in chapter until duration ≥ target.
    Emits one combined WAV + expected.json built from the concatenated transcript."""
    flacs = sorted(chapter_dir.glob("*.flac"))
    picked: list[Path] = []
    combined_text: list[str] = []
    total = 0.0
    for flac in flacs:
        dur = flac_duration(flac)
        picked.append(flac)
        combined_text.append(transcripts.get(flac.stem, ""))
        total += dur
        if total >= target_duration:
            break
    if total < target_duration:
        log(f"  [skip] {chapter_dir} only has {total:.1f}s, below target {target_duration}")
        return None

    wav = FIXTURES_DIR / f"{out_name}.wav"
    meta = FIXTURES_DIR / f"{out_name}.expected.json"
    concat_flacs_to_wav(picked, wav)

    text = " ".join(combined_text)
    keywords = pick_keywords(text, count=3)
    # Long → expect ≥ 2 streaming partials (VAD will find utterance boundaries
    # since we literally concatenated separate utterances).
    write_meta(meta, keywords, text, streaming_min=2)
    ids = [f.stem for f in picked]
    log(f"✓ {out_name}.wav ({total:.1f}s, {len(picked)} utterances concatenated) — keywords {keywords}")
    return f"{out_name}: LibriSpeech dev-clean, concat of {ids[0]}..{ids[-1]}"


def main() -> int:
    ensure_tarball()
    ensure_extracted()

    chapters = discover_chapters()
    if not chapters:
        print("ERROR: no chapters found under dev-clean.", file=sys.stderr)
        return 1

    log(f"Found {len(chapters)} chapters in dev-clean")

    attributions: list[str] = []

    # ---- Shorts: pick 7 diverse (speaker, chapter) dirs ----
    used_speakers: set[str] = set()
    short_count = 0
    for chap_dir, _trans_file, trans in chapters:
        speaker = chap_dir.parent.name
        if speaker in used_speakers:
            continue
        name = f"librispeech_{speaker}_{chap_dir.name}_short"
        attr = make_short_fixture(chap_dir, trans, name)
        if attr is not None:
            attributions.append(attr)
            used_speakers.add(speaker)
            short_count += 1
        if short_count >= 7:
            break

    log(f"Short fixtures produced: {short_count}/7")

    # ---- Longs: first two chapters whose total flac duration ≥ 65 s ----
    long_count = 0
    used_chapters: set[str] = set()
    for chap_dir, _trans_file, trans in chapters:
        total = sum(flac_duration(f) for f in sorted(chap_dir.glob("*.flac")))
        if total < 70.0:
            continue
        chapter_key = f"{chap_dir.parent.name}-{chap_dir.name}"
        if chapter_key in used_chapters:
            continue
        target = 65.0 if long_count == 0 else 95.0
        name = f"librispeech_{chap_dir.parent.name}_{chap_dir.name}_long"
        attr = make_long_fixture(chap_dir, trans, name, target_duration=target)
        if attr is not None:
            attributions.append(attr)
            used_chapters.add(chapter_key)
            long_count += 1
        if long_count >= 2:
            break

    log(f"Long fixtures produced: {long_count}/2")

    # ---- Attribution appendix ----
    if attributions:
        marker = "\n## LibriSpeech dev-clean fixtures\n"
        block = marker + "\n- **Corpus**: LibriSpeech dev-clean (Vassil Panayotov et al., 2015)\n"
        block += "- **License**: CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/\n"
        block += "- **Underlying recordings**: Public domain, from LibriVox audiobooks.\n"
        block += "- **Citation**: Panayotov, V. et al. \"LibriSpeech: an ASR corpus based on public domain audio books.\" ICASSP 2015.\n\n"
        block += "Fixtures extracted:\n"
        for a in attributions:
            block += f"- {a}\n"

        current = ATTRIBUTION.read_text() if ATTRIBUTION.exists() else ""
        if marker not in current:
            ATTRIBUTION.write_text(current + block)
            log("✓ Appended attribution block")

    return 0


if __name__ == "__main__":
    sys.exit(main())
