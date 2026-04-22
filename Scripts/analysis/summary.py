#!/usr/bin/env python3
"""Top-line dogfood summary: how many sessions, what backends, how long,
which languages, profile hit rate, skipped-injection rate.

Answers "is dogfood pool deep enough yet?" and "where is most of the data
sitting?" so v0.5.3 advancement decisions have a number to cite.

Usage:
  python3 summary.py <capture-root-or-single-session>

Schema: ../../docs/debug-captures.md
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

from _common import (
    dir_size_bytes,
    fmt_pct,
    human_bytes,
    iter_sessions,
    load_injections,
    load_meta,
    percentiles,
)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root dir or single session dir")
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    metas: list[dict] = []
    audio_lengths: list[float] = []
    by_backend: Counter = Counter()
    by_backend_audio: defaultdict = defaultdict(float)
    by_lang: Counter = Counter()
    profile_hits = 0
    total_segments = 0
    total_injections = 0
    skipped_injections = 0
    live_count = 0
    on_disk = 0

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        metas.append(meta)

        backend = meta.get("backend", "unknown")
        audio = float(meta.get("totalAudioSec", 0.0))
        live = bool(meta.get("liveMode", False))
        lang = meta.get("language", "unknown")
        snippet = (meta.get("profileSnippet") or "").strip()

        audio_lengths.append(audio)
        by_backend[backend] += 1
        by_backend_audio[backend] += audio
        by_lang[lang] += 1
        if snippet:
            profile_hits += 1
        if live:
            live_count += 1

        total_segments += int(meta.get("totalSegments", 0))
        total_injections += int(meta.get("totalInjections", 0))

        for inj in load_injections(sd):
            if inj.get("status") == "skipped":
                skipped_injections += 1

        on_disk += dir_size_bytes(sd)

    n = len(metas)
    if n == 0:
        print("No readable sessions.")
        return 1

    audio_total_min = sum(audio_lengths) / 60.0
    pcts = percentiles(audio_lengths, ps=(50, 95, 99))
    audio_max = max(audio_lengths) if audio_lengths else 0

    print(f"Sessions:    {n}  (live: {live_count}  /  batch: {n - live_count})")
    print(f"Audio total: {audio_total_min:.1f} min")
    print(f"Segments:    {total_segments}  (avg {total_segments / n:.1f}/session)")
    print(f"Injections:  {total_injections}  (avg {total_injections / n:.1f}/session)")
    print(f"On-disk:     {human_bytes(on_disk)}")
    print()

    print("Audio length distribution (per session):")
    print(f"  p50  {pcts[50]:>5.1f} s")
    print(f"  p95  {pcts[95]:>5.1f} s")
    print(f"  p99  {pcts[99]:>5.1f} s")
    print(f"  max  {audio_max:>5.1f} s")
    print()

    print("Per-backend:")
    for backend, count in by_backend.most_common():
        mins = by_backend_audio[backend] / 60.0
        print(f"  {backend:<22} {count:>4}  ({mins:>5.1f} min, {fmt_pct(count, n)})")
    print()

    print("Language split:")
    for lang, count in by_lang.most_common():
        print(f"  {lang:<22} {count:>4}  ({fmt_pct(count, n)})")
    print()

    print(f"Profile hit rate:    {profile_hits} / {n} sessions ({fmt_pct(profile_hits, n)})")
    print(
        f"Skipped injections:  {skipped_injections} / {total_injections} "
        f"({fmt_pct(skipped_injections, total_injections)})"
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
