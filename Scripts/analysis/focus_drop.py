#!/usr/bin/env python3
"""Tally injections that didn't land where the user pointed Fn at.

Two failure modes share the "didn't land" bucket:
  - status=focusChanged → user moved focus mid-recording, v0.5.0 detector
    refused to inject into the wrong app
  - status=skipped → zero text, target app gone, or pasteboard hop refused
    (usually safe, but worth tracking — high rate suggests an upstream gap)

Per-target-bundleID breakdown sorted by drop rate desc surfaces app-specific
issues. Electron apps (Slack, Discord, VS Code) and Chrome are common
NSWorkspace activation race victims; if one of them is way above the others,
that's a hint where to instrument next.

Decision support: scope doc says < 5% overall drop rate is acceptable; any
single app > 10% warrants investigation.

Usage:
  python3 focus_drop.py <capture-root-or-single-session>
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

from _common import fmt_pct, iter_sessions, load_injections


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    p.add_argument(
        "--min-sessions",
        type=int,
        default=3,
        help="hide apps with fewer than N injections in the per-app table",
    )
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    # per-target-bundleID totals
    total_by_app: defaultdict = defaultdict(int)
    focus_changed_by_app: defaultdict = defaultdict(int)
    skipped_by_app: defaultdict = defaultdict(int)

    grand_total = 0
    grand_focus_changed = 0
    grand_skipped = 0

    for sd in sessions:
        for inj in load_injections(sd):
            target = inj.get("targetBundleID") or "<unknown>"
            status = inj.get("status", "ok")
            total_by_app[target] += 1
            grand_total += 1
            if status == "focusChanged":
                focus_changed_by_app[target] += 1
                grand_focus_changed += 1
            elif status == "skipped":
                skipped_by_app[target] += 1
                grand_skipped += 1

    if grand_total == 0:
        print("No injections recorded.")
        return 0

    grand_dropped = grand_focus_changed + grand_skipped
    print(
        f"Drops: {grand_focus_changed} focusChanged + {grand_skipped} skipped / "
        f"{grand_total} injections ({fmt_pct(grand_dropped, grand_total)})"
    )
    print()

    # Per-app table — sort by drop rate desc within apps that meet the
    # min-sessions threshold so single-injection outliers don't dominate.
    print(f"Per target app (≥ {args.min_sessions} injections):")
    rows = []
    for app, total in total_by_app.items():
        if total < args.min_sessions:
            continue
        fc = focus_changed_by_app[app]
        sk = skipped_by_app[app]
        dropped = fc + sk
        rate = dropped / total
        rows.append((rate, app, total, fc, sk))
    rows.sort(reverse=True)

    if not rows:
        print(f"  (no app has ≥ {args.min_sessions} injections yet)")
    else:
        # Header
        print(f"  {'app':<40} {'total':>5} {'focChg':>6} {'skip':>5} {'drop%':>6}")
        for rate, app, total, fc, sk in rows:
            shown = app if len(app) <= 40 else app[:37] + "..."
            print(f"  {shown:<40} {total:>5} {fc:>6} {sk:>5} {rate * 100:>5.1f}%")

    # Quietly note hidden apps so users know their long tail wasn't lost
    hidden = sum(1 for total in total_by_app.values() if total < args.min_sessions)
    if hidden:
        print()
        print(f"  ({hidden} app(s) hidden — fewer than {args.min_sessions} injections)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
