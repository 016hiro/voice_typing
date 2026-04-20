#!/usr/bin/env python3
"""
Pull a handful of Mandarin Chinese regression-test fixtures from FLEURS.

FLEURS (Few-shot Learning Evaluation of Universal Representations of Speech)
is Google's multilingual ASR benchmark, CC BY 4.0, with aligned transcripts.
We use the `cmn_hans_cn` split (Mandarin, Simplified) — dev subset, ~207 MB.

Strategy:
  Pick 5 utterances with distinct transcripts and a spread of durations
  (short / medium / long / xlong), diverse speakers where possible.
  Convert each to 16 kHz mono s16 WAV (FLEURS ships 16 kHz mono pcm_f32le).
  Emit expected.json with length bounds derived from the transcript length;
  leave `keywords` empty — the batch-vs-streaming diff is the primary signal,
  and you can add specific keywords later if you want a hard bar.

Run via `Scripts/fetch_english_fixtures.sh` (which calls this after fetching
the JFK clip), not directly.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tarfile
from collections import defaultdict
from pathlib import Path
from typing import Optional

CACHE_DIR = Path.home() / ".cache" / "vt-fixtures"
TARBALL = CACHE_DIR / "fleurs-cmn_hans_cn-dev.tar.gz"
TSV = CACHE_DIR / "fleurs-cmn_hans_cn-dev.tsv"
EXTRACT_DIR = CACHE_DIR / "fleurs-cmn_hans_cn"
TARBALL_URL = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/cmn_hans_cn/audio/dev.tar.gz"
TSV_URL = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/cmn_hans_cn/dev.tsv"

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURES_DIR = REPO_ROOT / "Tests" / "Fixtures"
ATTRIBUTION = FIXTURES_DIR / "ATTRIBUTION.md"


def log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def ensure_downloads() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if not TARBALL.exists() or TARBALL.stat().st_size < 100_000_000:
        log(f"↓ Downloading FLEURS cmn_hans_cn dev (~207 MB) to {TARBALL}")
        subprocess.run(
            ["curl", "-fL", "--progress-bar", "-o", str(TARBALL), TARBALL_URL],
            check=True,
        )
    else:
        log(f"✓ FLEURS tarball cached: {TARBALL}")

    if not TSV.exists() or TSV.stat().st_size < 1000:
        log(f"↓ Downloading FLEURS transcripts (~500 KB) to {TSV}")
        subprocess.run(
            ["curl", "-fL", "-o", str(TSV), TSV_URL],
            check=True,
        )
    else:
        log(f"✓ FLEURS TSV cached: {TSV}")


def ensure_extracted() -> None:
    dev_dir = EXTRACT_DIR / "dev"
    if dev_dir.exists() and any(dev_dir.iterdir()):
        log(f"✓ Already extracted at {EXTRACT_DIR}")
        return
    log(f"→ Extracting to {EXTRACT_DIR}")
    EXTRACT_DIR.mkdir(parents=True, exist_ok=True)
    with tarfile.open(TARBALL, "r:gz") as tar:
        tar.extractall(path=EXTRACT_DIR)


def parse_tsv() -> list[dict]:
    """Return a list of utterance dicts parsed from dev.tsv. Columns:
       id, filename, transcript, tokenized, piped, num_samples, gender."""
    rows: list[dict] = []
    for line in TSV.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        try:
            num_samples = int(parts[5])
        except ValueError:
            continue
        rows.append({
            "id": parts[0],
            "filename": parts[1],
            "transcript": parts[2].strip(),
            "num_samples": num_samples,
            "gender": parts[6].strip(),
            "duration": num_samples / 16000.0,
        })
    return rows


def pick_fixtures(rows: list[dict], target_n: int = 5) -> list[dict]:
    """Pick N utterances with:
       - distinct transcripts (no duplicates from different speakers)
       - duration spread across short / med / long / xlong buckets
       - gender mix if possible
    """
    seen_transcripts: set[str] = set()
    by_bucket: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        t = row["transcript"]
        if t in seen_transcripts:
            continue
        seen_transcripts.add(t)
        d = row["duration"]
        if d < 4.5:
            bucket = "short"
        elif d < 8:
            bucket = "medium_short"
        elif d < 12:
            bucket = "medium"
        elif d < 18:
            bucket = "long"
        else:
            bucket = "xlong"
        by_bucket[bucket].append(row)

    picks: list[dict] = []
    # Sort each bucket by duration ascending for stable selection.
    for bucket in ("short", "medium_short", "medium", "long", "xlong"):
        candidates = sorted(by_bucket[bucket], key=lambda r: (r["duration"], r["id"]))
        if not candidates:
            continue
        pick = candidates[0]
        # Gender balance pass: if last pick was same gender and we have an alternative, swap.
        if picks and pick["gender"] == picks[-1]["gender"]:
            alt = next((c for c in candidates if c["gender"] != picks[-1]["gender"]), None)
            if alt is not None:
                pick = alt
        picks.append(pick)
        if len(picks) >= target_n:
            break
    return picks


def convert_to_wav(src: Path, dst: Path) -> None:
    """FLEURS audio is 16 kHz mono pcm_f32le; convert to s16 to match our
    canonical fixture format (smaller file, same range for speech)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(src),
         "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(dst)],
        check=True,
    )


def write_expected(meta_path: Path, transcript: str, streaming_min: int) -> None:
    """Emit expected.json with length bounds from transcript length. Keywords
    stay empty — the comparison test checks length bounds + batch/streaming
    similarity without needing hand-picked keywords. User edits to tighten."""
    char_count = sum(1 for c in transcript if '\u4e00' <= c <= '\u9fff')
    # Generous range: ASR output may be slightly shorter/longer than reference
    # (punctuation, number spellings, etc.), and we want to tolerate small
    # drifts across Qwen model updates.
    min_chars = max(5, int(char_count * 0.4))
    max_chars = max(50, int(char_count * 3))
    meta = {
        "keywords": [],
        "minChars": min_chars,
        "maxChars": max_chars,
        "language": "zh-CN",
        "streamingMinPartials": streaming_min,
    }
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")


def build_name(bucket_label: str, row: dict) -> str:
    dur_int = int(round(row["duration"]))
    gender = row["gender"].lower()[:1]  # m / f
    # Short deterministic suffix so the name sorts nicely and two fixtures
    # from the same bucket don't collide.
    suffix = row["id"][-4:]
    return f"fleurs_zh_{bucket_label}_{dur_int}s_{gender}_{suffix}"


def main() -> int:
    ensure_downloads()
    ensure_extracted()

    rows = parse_tsv()
    if not rows:
        print("ERROR: no rows in TSV", file=sys.stderr)
        return 1

    picks = pick_fixtures(rows, target_n=5)
    if not picks:
        print("ERROR: no fixtures picked", file=sys.stderr)
        return 1

    log(f"Picked {len(picks)} Mandarin fixtures from FLEURS dev:")
    attributions: list[str] = []
    for row in picks:
        src = EXTRACT_DIR / "dev" / row["filename"]
        if not src.exists():
            log(f"  [skip] {row['filename']} not found in tarball")
            continue

        # Name uses a bucket label derived from duration for readability.
        dur = row["duration"]
        if dur < 4.5:
            bucket_label = "short"
        elif dur < 8:
            bucket_label = "med"
        elif dur < 12:
            bucket_label = "medlong"
        elif dur < 18:
            bucket_label = "long"
        else:
            bucket_label = "xlong"

        name = build_name(bucket_label, row)
        wav = FIXTURES_DIR / f"{name}.wav"
        meta = FIXTURES_DIR / f"{name}.expected.json"

        convert_to_wav(src, wav)
        # Long fixtures likely split by VAD; bump streaming expectation.
        streaming_min = 2 if dur > 12 else 1
        write_expected(meta, row["transcript"], streaming_min=streaming_min)

        log(f"  ✓ {name}.wav ({dur:.1f}s, {row['gender']}): {row['transcript'][:40]}…")
        attributions.append(
            f"{name}: FLEURS dev #{row['id']} file {row['filename']} ({row['gender']}, {dur:.1f}s)"
        )

    # Attribution block — append once.
    if attributions:
        marker = "\n## FLEURS Mandarin (cmn_hans_cn) fixtures\n"
        block = marker + "\n- **Corpus**: FLEURS (Few-shot Learning Evaluation of Universal Representations of Speech), `cmn_hans_cn` dev split\n"
        block += "- **Source**: [google/fleurs on Hugging Face](https://huggingface.co/datasets/google/fleurs)\n"
        block += "- **License**: CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/\n"
        block += "- **Citation**: Conneau, A. et al. \"FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech.\" IEEE SLT 2022.\n\n"
        block += "Fixtures extracted:\n"
        for a in attributions:
            block += f"- {a}\n"
        current = ATTRIBUTION.read_text() if ATTRIBUTION.exists() else ""
        if marker not in current:
            ATTRIBUTION.write_text(current + block)
            log("  ✓ Appended FLEURS attribution block")

    return 0


if __name__ == "__main__":
    sys.exit(main())
