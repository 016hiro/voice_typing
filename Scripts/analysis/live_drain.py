#!/usr/bin/env python3
"""Live mode drain time: how long between Fn↑ and the last segment landing.

Live mode's headline promise is `perceived_latency = ASR(last_segment) + drain`
where drain is whatever the segment-already-in-flight has left to finish + the
inject hop. This script measures that gap directly.

Skips batch sessions — drain has no meaning when transcription happens
strictly after Fn↑.

Decision support: scope doc says p95 > 500ms is "investigate the bottleneck"
(maxTokens saturating, Metal queue backing up, dl_init still firing).

Usage:
  python3 live_drain.py <capture-root-or-single-session>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from _common import (
    histogram_ascii,
    iter_sessions,
    load_injections,
    load_meta,
    parse_iso,
    percentiles,
)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    drains_ms: list[float] = []
    skipped_no_inject = 0
    skipped_not_live = 0
    skipped_bad_ts = 0

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        if not meta.get("liveMode"):
            skipped_not_live += 1
            continue

        ended = meta.get("endedAt")
        if not ended:
            skipped_bad_ts += 1
            continue

        injections = load_injections(sd)
        # Only count successful or focusChanged injections — skipped (zero
        # text, target gone) never actually landed text and would skew the
        # tail. Sort defensively even though they should already be append-
        # ordered.
        landed = [
            inj for inj in injections
            if inj.get("status") in ("ok", "focusChanged") and inj.get("timestamp")
        ]
        if not landed:
            skipped_no_inject += 1
            continue
        landed.sort(key=lambda i: i["timestamp"])
        last_inject_ts = landed[-1]["timestamp"]

        try:
            delta_ms = (parse_iso(last_inject_ts) - parse_iso(ended)).total_seconds() * 1000
        except ValueError:
            skipped_bad_ts += 1
            continue

        # Negative delta means last segment landed before Fn↑ (legit when the
        # user releases right as the inject completes). Clamp to 0 for the
        # latency view — they're functionally "instant".
        drains_ms.append(max(0.0, delta_ms))

    if not drains_ms:
        print("No live sessions with usable drain timestamps.")
        if skipped_not_live:
            print(f"  ({skipped_not_live} batch sessions skipped, by design)")
        if skipped_no_inject:
            print(f"  ({skipped_no_inject} live sessions had no landed injections)")
        if skipped_bad_ts:
            print(f"  ({skipped_bad_ts} sessions had unparseable timestamps)")
        return 0

    pcts = percentiles(drains_ms, ps=(50, 90, 95, 99))
    print(f"Live drain time across {len(drains_ms)} sessions:")
    print(f"  p50  {pcts[50]:>6.0f} ms")
    print(f"  p90  {pcts[90]:>6.0f} ms")
    print(f"  p95  {pcts[95]:>6.0f} ms")
    print(f"  p99  {pcts[99]:>6.0f} ms")
    print(f"  max  {max(drains_ms):>6.0f} ms")
    print()

    # 100ms buckets up to ~2s; everything beyond goes into one tail bucket
    # implicitly (histogram_ascii caps at the actual max).
    print("Histogram (bucket = 100ms):")
    print(histogram_ascii(drains_ms, bucket=100, label=""))

    if skipped_not_live or skipped_no_inject or skipped_bad_ts:
        print()
        print(
            f"Skipped: {skipped_not_live} batch  /  "
            f"{skipped_no_inject} live-no-inject  /  "
            f"{skipped_bad_ts} bad-timestamp"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
