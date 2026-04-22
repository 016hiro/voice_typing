#!/usr/bin/env python3
"""List every segment HallucinationFilter rejected so they can be eyeballed
against the v0.4.5 rule set.

Output:
  - filter rate overall + per-backend (smaller models tend to hallucinate
    training-set tails more — per-backend lets us tune thresholds differently
    if the data demands it)
  - one line per filtered segment: timestamp, session, position, rawText
  - --sample N picks N random filtered segments (avoid scrolling through
    hundreds when dogfood pool is large)

Decision support: scope doc says ≥ 20% of filtered segments being real
speech means relax thresholds. This script gives you the input; the human
calls the rate.

Usage:
  python3 hallucination_review.py <capture-root-or-single-session> [--sample N]
"""

from __future__ import annotations

import argparse
import random
import sys
from collections import defaultdict
from pathlib import Path

from _common import fmt_pct, iter_sessions, load_meta, load_segments


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    p.add_argument(
        "--sample",
        type=int,
        default=None,
        help="randomly sample N filtered segments instead of listing all",
    )
    p.add_argument("--seed", type=int, default=None, help="random seed for --sample reproducibility")
    args = p.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    by_backend_total: defaultdict = defaultdict(int)
    by_backend_filtered: defaultdict = defaultdict(int)
    filtered_rows: list[tuple[str, str, str, float, float, str]] = []
    # (backend, session_id, when, startSec, endSec, rawText)

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        backend = meta.get("backend", "unknown")
        session_label = sd.name

        for seg in load_segments(sd):
            by_backend_total[backend] += 1
            if seg.get("filter") == "hallucinationFiltered":
                by_backend_filtered[backend] += 1
                filtered_rows.append(
                    (
                        backend,
                        session_label,
                        seg.get("timestamp", "?"),
                        float(seg.get("startSec", 0.0)),
                        float(seg.get("endSec", 0.0)),
                        seg.get("rawText", ""),
                    )
                )

    total_segments = sum(by_backend_total.values())
    total_filtered = sum(by_backend_filtered.values())

    print(
        f"Filtered: {total_filtered} / {total_segments} segments "
        f"({fmt_pct(total_filtered, total_segments)})"
    )
    print()

    if not by_backend_total:
        print("No segments parsed.")
        return 0

    print("Per-backend filter rate:")
    # sort by total segments desc so the most-used backend shows first
    for backend, total in sorted(by_backend_total.items(), key=lambda kv: -kv[1]):
        filt = by_backend_filtered[backend]
        print(f"  {backend:<22} {filt:>4} / {total:>4}  ({fmt_pct(filt, total)})")
    print()

    if not filtered_rows:
        print("No filtered segments to list.")
        return 0

    rows = filtered_rows
    if args.sample is not None and args.sample < len(rows):
        rows = random.sample(rows, args.sample)
        # Re-sort sampled rows by timestamp so the eyeballing stays chronological
        rows.sort(key=lambda r: r[2])
        print(f"Sample of {args.sample} filtered segments:")
    else:
        print("Filtered segments:")

    for backend, session_label, ts, s, e, text in rows:
        # Truncate long lines to keep terminal output readable; 120 chars
        # mirrors the textPreview cap in injections.jsonl.
        snippet = text if len(text) <= 120 else text[:117] + "..."
        print(f"  [{ts}  {backend:<14} {session_label}  {s:>5.2f}-{e:<5.2f}s] {snippet!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
