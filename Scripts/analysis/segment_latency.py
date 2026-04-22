#!/usr/bin/env python3
"""Per-segment ASR latency + Real-Time Factor (RTF) + cold/warm split.

Why this matters: live_drain.py measures only the tail (last segment after
Fn↑). Mid-recording, the user feels every individual segment's ASR latency.
If transcribeMs sits high, live mode feels stuttery even when drain is fast.

RTF = transcribeMs / segment_audio_ms
  RTF < 1.0  → ASR faster than real-time (live mode comfortable)
  RTF > 1.0  → ASR slower than real-time (segments queue, live mode broken)

Cold-vs-warm: per session, the first segment includes any leftover warmup
cost (Metal kernel JIT, model paging). Comparing first vs subsequent segments
exposes whether v0.5.1's dl_init fix is actually doing its job in real
sessions or whether warmup leaks back in.

Usage:
  python3 segment_latency.py <capture-root-or-single-session>
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

from _common import fmt_ms, iter_sessions, load_meta, load_segments, percentiles


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    all_ms: list[float] = []
    by_backend_ms: defaultdict = defaultdict(list)
    by_backend_rtf: defaultdict = defaultdict(list)
    first_seg_ms: list[float] = []
    rest_seg_ms: list[float] = []
    seg_count = 0

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        backend = meta.get("backend", "unknown")
        segs = load_segments(sd)
        if not segs:
            continue

        # Sort by startSec just in case writes interleave; we want chronological
        # order to label "first" correctly.
        segs.sort(key=lambda s: float(s.get("startSec", 0.0)))

        for idx, seg in enumerate(segs):
            ms = seg.get("transcribeMs")
            if ms is None:
                continue
            ms = float(ms)
            all_ms.append(ms)
            by_backend_ms[backend].append(ms)
            seg_count += 1

            if idx == 0:
                first_seg_ms.append(ms)
            else:
                rest_seg_ms.append(ms)

            # RTF needs a positive segment duration; guard divide-by-zero
            # for the rare 0-length segment that slips past VAD.
            duration_sec = float(seg.get("endSec", 0.0)) - float(seg.get("startSec", 0.0))
            if duration_sec > 0:
                rtf = (ms / 1000.0) / duration_sec
                by_backend_rtf[backend].append(rtf)

    if not all_ms:
        print("No segments with transcribeMs found.")
        return 0

    pcts = percentiles(all_ms, ps=(50, 90, 95, 99))
    print(f"Per-segment ASR latency across {seg_count} segments:")
    print(f"  p50  {fmt_ms(pcts[50])}")
    print(f"  p90  {fmt_ms(pcts[90])}")
    print(f"  p95  {fmt_ms(pcts[95])}")
    print(f"  p99  {fmt_ms(pcts[99])}")
    print(f"  max  {fmt_ms(max(all_ms))}")
    print()

    print("Per-backend RTF (transcribeMs / audio_ms; <1 = faster than real-time):")
    for backend in sorted(by_backend_ms.keys()):
        ms_pcts = percentiles(by_backend_ms[backend], ps=(50, 95))
        rtfs = by_backend_rtf[backend]
        if rtfs:
            rtf_pcts = percentiles(rtfs, ps=(50, 95))
            print(
                f"  {backend:<22} ms p50={ms_pcts[50]:>5.0f}  p95={ms_pcts[95]:>5.0f}    "
                f"rtf p50={rtf_pcts[50]:>4.2f}  p95={rtf_pcts[95]:>4.2f}    n={len(rtfs)}"
            )
        else:
            print(f"  {backend:<22} ms p50={ms_pcts[50]:>5.0f}  p95={ms_pcts[95]:>5.0f}    rtf n/a")
    print()

    if first_seg_ms and rest_seg_ms:
        first_p50 = percentiles(first_seg_ms, ps=(50,))[50]
        rest_p50 = percentiles(rest_seg_ms, ps=(50,))[50]
        # Express delta as % of rest baseline; > 50% suggests warmup hasn't
        # been amortized — worth instrumenting prepare() further.
        if rest_p50 > 0:
            delta_pct = (first_p50 - rest_p50) / rest_p50 * 100
            tag = "  ← warmup likely still present" if delta_pct > 50 else ""
        else:
            delta_pct = 0
            tag = ""
        print("Cold-vs-warm (first segment vs rest, per session):")
        print(f"  first  p50  {fmt_ms(first_p50)}    n={len(first_seg_ms)}")
        print(f"  rest   p50  {fmt_ms(rest_p50)}    n={len(rest_seg_ms)}")
        print(f"  delta       {delta_pct:+.0f}%{tag}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
