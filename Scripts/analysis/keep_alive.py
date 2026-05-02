#!/usr/bin/env python3
"""Per-build keep-alive timer activity (v0.7.1 #B3 diagnostic).

The v0.6.4 ASR keep-alive shipped to fix cold-decompress outliers but the
post-ship dogfood data showed ≥5s outlier rate got *worse* (2.2% → 5.3%).
v0.7.1 adds App Nap suppression + wake-from-sleep handler + observability.
This script reads `Meta.keepAliveTicksAtStart` / `keepAliveTicksAtEnd`
(v0.7.1+) sliced by `gitCommitSHA` to answer "did the timer actually fire
in dogfood, and is the v0.7.1 fix doing its job?"

Output buckets per build:
  - sessions where ticksAtStart > 0  → keep-alive fired by session begin
  - sessions where ticksAtStart == 0 → process just launched (expected)
  - sessions where ticksAtStart is None → pre-v0.7.1 capture (no field)

A healthy v0.7.1 build's 90s+ uptime sessions should have ticksAtStart > 0
overwhelmingly. If the rate is low, App Nap suppression is broken.

Usage:
  python3 keep_alive.py <capture-root-or-single-session>
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

from _common import fmt_pct, iter_sessions, load_meta, parse_iso, percentiles


def _build_key(meta: dict) -> str:
    # Prefer SHA when present (post-v0.7.1); fall back to version string for
    # older captures so they still group sensibly. Pre-v0.7.1 captures lack
    # `gitCommitSHA` entirely.
    ver = meta.get("appVersion") or "?"
    sha = meta.get("gitCommitSHA")
    if sha:
        return f"{ver}@{sha}"
    return ver


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    by_build: dict[str, dict] = defaultdict(lambda: {
        "n": 0,
        "ticks_start_present": 0,
        "ticks_start_positive": 0,
        "ticks_start_zero": 0,
        "ticks_at_start": [],
        "ticks_at_end": [],
        "session_durations": [],
    })

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        b = by_build[_build_key(meta)]
        b["n"] += 1

        ts = meta.get("keepAliveTicksAtStart")
        te = meta.get("keepAliveTicksAtEnd")
        if ts is not None:
            b["ticks_start_present"] += 1
            b["ticks_at_start"].append(int(ts))
            if int(ts) > 0:
                b["ticks_start_positive"] += 1
            else:
                b["ticks_start_zero"] += 1
        if te is not None:
            b["ticks_at_end"].append(int(te))

        # Session duration = endedAt - startedAt; useful for "was this session
        # long enough that a tick should have fired during it?"
        try:
            started = parse_iso(meta["startedAt"])
            ended_raw = meta.get("endedAt")
            if ended_raw:
                ended = parse_iso(ended_raw)
                b["session_durations"].append((ended - started).total_seconds())
        except (KeyError, ValueError, TypeError):
            pass

    if not by_build:
        print("No sessions with readable meta.")
        return 0

    # Sort builds chronologically by chosen order: pre-v0.7.1 (no SHA) first,
    # then SHA-tagged builds alphabetically (rough proxy for ship order).
    pre_v071 = sorted(b for b in by_build if "@" not in b)
    tagged = sorted(b for b in by_build if "@" in b)
    ordered = pre_v071 + tagged

    print(f"{'Build':<36} {'sess':>5} {'instr':>6} {'>0':>5} {'==0':>5} {'p50':>5} {'p95':>5} {'>30s sess':>9}")
    print("-" * 90)
    for build in ordered:
        b = by_build[build]
        n = b["n"]
        instr = b["ticks_start_present"]
        if b["ticks_at_start"]:
            pcts = percentiles(b["ticks_at_start"], ps=(50, 95))
            p50 = f"{pcts[50]:.0f}"
            p95 = f"{pcts[95]:.0f}"
        else:
            p50 = "—"
            p95 = "—"
        long_sess = sum(1 for d in b["session_durations"] if d > 30)
        print(
            f"{build:<36} {n:>5} {instr:>6} "
            f"{b['ticks_start_positive']:>5} {b['ticks_start_zero']:>5} "
            f"{p50:>5} {p95:>5} {long_sess:>9}"
        )

    print()
    print("Columns:")
    print("  sess       — total sessions for this build")
    print("  instr      — sessions with `keepAliveTicksAtStart` field present (v0.7.1+)")
    print("  >0         — sessions where keep-alive had already fired ≥1 tick when session began")
    print("  ==0        — sessions where keep-alive had not fired yet (process just launched, or broken)")
    print("  p50 / p95  — distribution of `keepAliveTicksAtStart` over instrumented sessions")
    print("  >30s sess  — sessions whose duration > 30s — within these the timer should certainly fire mid-session")
    print()
    print("Healthy v0.7.1+ build: `>0` should dominate `==0` for any build with > a few sessions,")
    print("because App Nap suppression keeps the 90s timer running across user idle.")

    # Cross-build anomaly check: if any post-v0.7.1 build has near-zero `>0`
    # rate over many sessions, flag it.
    print()
    issues = []
    for build in tagged:
        b = by_build[build]
        if b["ticks_start_present"] >= 10:
            ratio = b["ticks_start_positive"] / b["ticks_start_present"]
            if ratio < 0.5:
                issues.append((build, ratio, b["ticks_start_present"]))
    if issues:
        print("⚠ Suspicious builds (instr ≥ 10 but >0 rate < 50%):")
        for build, ratio, instr in issues:
            print(f"   {build}    {ratio*100:.0f}% of {instr} sessions")
    else:
        print("No suspicious builds flagged.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
