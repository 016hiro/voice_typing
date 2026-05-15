#!/usr/bin/env python3
"""Skip-gate live telemetry report — answers the v0.8.0 #S1 deployment
question:

  "After the heuristic is on, what fraction of short refines actually got
  skipped, and how much LLM time did that buy?"

Reads `refines.jsonl` from dogfood sessions and groups by the v0.8.0 `gate`
field added in `RefineRecord`:

  - `skipped`           : Variant C rule said skip, no hotword guard blocked
  - `rule`              : Variant C rule fired → refine ran
  - `hotword_substring` : Layer 1 substring guard blocked the skip
  - `hotword_phonetic`  : Layer 2 phonetic guard blocked the skip
  - (absent)            : pre-v0.8.0 record or non-S1 refine path (cloud
                          one-shot, batch session-end). Reported as "ungated".

Saved-latency estimate: for each `skipped` record, attribute the median
`latencyMs` of `rule`-gated records (= refines on similarly-short inputs that
DID run). Conservative because rule-gated inputs are by definition rejected
by the heuristic, so a baseline closer to "would-have-been-skipped if no
hotword" — exactly the counterfactual. If insufficient `rule` records,
falls back to global median across all non-skipped records.

Run:
  uv run skip_gate_report.py <capture-root>
  uv run skip_gate_report.py <capture-root> --since 2026-05-15
"""

from __future__ import annotations

import argparse
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

from _common import iter_sessions, load_refines


def parse_iso(s: str) -> datetime | None:
    if not s:
        return None
    try:
        # Accept "2026-05-15T12:34:56Z" or "2026-05-15"
        if "T" in s:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("captures", type=Path,
                   help="capture root or single session dir")
    p.add_argument("--since", type=str, default=None,
                   help="filter records by timestamp ≥ this ISO date "
                        "(useful for post-v0.8.0-release comparisons)")
    args = p.parse_args()

    cutoff = parse_iso(args.since) if args.since else None

    records: list[dict] = []
    for sd in iter_sessions(args.captures):
        for r in load_refines(sd):
            if cutoff:
                rt = parse_iso(r.get("timestamp", ""))
                if rt is None or rt < cutoff:
                    continue
            records.append(r)

    if not records:
        print(f"No refine records under {args.captures}"
              + (f" (after {args.since})" if cutoff else ""))
        return 1

    # Bucket by gate
    buckets: dict[str, list[dict]] = {}
    for r in records:
        gate = r.get("gate") or "ungated"
        buckets.setdefault(gate, []).append(r)

    total = len(records)
    s1_total = sum(len(v) for k, v in buckets.items() if k != "ungated")

    print(f"Total refine records: {total}")
    print(f"  with gate label (v0.8.0+): {s1_total}")
    print(f"  ungated (pre-v0.8.0 or non-S1 path): {len(buckets.get('ungated', []))}")
    print()

    # Distribution
    print("=" * 60)
    print(f"Gate distribution ({s1_total} v0.8.0 records)")
    print("=" * 60)
    order = ["skipped", "rule", "hotword_substring", "hotword_phonetic"]
    for gate in order:
        recs = buckets.get(gate, [])
        if s1_total == 0:
            pct = 0.0
        else:
            pct = len(recs) / s1_total * 100
        print(f"  {gate:<22} {len(recs):>4}  ({pct:5.1f}%)")
    print()

    # Saved latency estimate. Use median rule-gated latencyMs as baseline
    # (the closest counterfactual: refines on short inputs that DID run).
    rule_latencies = [r.get("latencyMs", 0) for r in buckets.get("rule", [])
                      if r.get("latencyMs", 0) > 0]
    if rule_latencies:
        baseline = statistics.median(rule_latencies)
        baseline_src = "rule-gated median"
    else:
        all_latencies = [r.get("latencyMs", 0) for r in records
                         if r.get("latencyMs", 0) > 0
                         and r.get("gate") != "skipped"]
        baseline = statistics.median(all_latencies) if all_latencies else 0.0
        baseline_src = "global non-skipped median (rule bucket empty)"

    skipped = buckets.get("skipped", [])
    saved_ms = int(baseline) * len(skipped)
    print("=" * 60)
    print("Latency win estimate")
    print("=" * 60)
    print(f"  baseline per-refine: {int(baseline)}ms  ({baseline_src})")
    print(f"  skipped refines:     {len(skipped)}")
    print(f"  estimated saved:     {saved_ms / 1000:.1f}s "
          f"({saved_ms / max(s1_total, 1):.0f}ms/refine averaged)")
    print()

    # Hotword guard FP monitoring — these are the "would-have-skipped but
    # didn't" records. Their `latencyMs` is real refine time spent — if a
    # high fraction of these are no-ops (input==output), the guard is
    # over-aggressive.
    guard_blocked = buckets.get("hotword_substring", []) + buckets.get("hotword_phonetic", [])
    if guard_blocked:
        noops = sum(1 for r in guard_blocked
                    if r.get("input", "").strip() == r.get("output", "").strip())
        print("=" * 60)
        print("Hotword guard FP signal")
        print("=" * 60)
        print(f"  guard-blocked refines: {len(guard_blocked)}")
        print(f"    of which no-op:      {noops}  ({noops/len(guard_blocked)*100:.1f}%)")
        print(f"  high no-op rate (>50%) suggests the guard is over-firing")
        print()

    # Sample skipped inputs so dogfood reader can sanity-check
    if skipped:
        print("=" * 60)
        print(f"Sample of skipped inputs (showing 8 of {len(skipped)})")
        print("=" * 60)
        for r in skipped[:8]:
            inp = r.get("input", "")
            print(f"  - {inp[:80]}{'...' if len(inp) > 80 else ''}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
