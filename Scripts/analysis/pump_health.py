#!/usr/bin/env python3
"""Live-mode pump health (v0.7.1 #B6 follow-up).

Why this script: dogfood data showed a tail-latency cliff — most live
sessions feel snappy (median tail 1.7 s) but ~5 % stall 20–35 s after Fn↑
even though every individual `model.transcribe` call stays under 1 s. The
watchdog at the MLX boundary captured nothing because the lost time was
upstream — segments simply weren't being EMITTED in real time.

The v0.7.1 #B6 instrumentation pierces that gap by recording, per chunk
inside `LiveTranscriber.runPump`:
  - chunk ingest→drain lag (AsyncStream queue residency)
  - inter-drain gap (pump task scheduling stalls)
  - per-chunk VAD process time
  - segment-emission path: speechEnded (live) vs force-split vs EOF flush

This script reads those fields out of `segments.jsonl` + `meta.json` and
flags sessions where streaming wasn't actually streaming.

Output: two views, selected by `--by`:
  - `--by build`   slice by appVersion[@gitCommitSHA] (default; mirrors
                   keep_alive.py / segment_latency.py for cross-build A/B)
  - `--by app`     slice by frontmostBundleID (terminal apps were over-
                   represented in the orphan-tail set; this checks if the
                   stall correlates with the foreground app's inject path)

Healthy session: firstSegLag < 1 s, flushTriggered ratio low, chunkLagMax
under a few hundred ms. Sick session: firstSegLag > 3 s, flushTriggered
ratio near 1.0, chunkLagMax in seconds.

Usage:
  python3 pump_health.py <capture-root>            # default --by build
  python3 pump_health.py <capture-root> --by app
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from statistics import median

from _common import iter_sessions, load_meta, load_segments, parse_iso, percentiles


def _build_key(meta: dict) -> str:
    ver = meta.get("appVersion") or "?"
    sha = meta.get("gitCommitSHA")
    return f"{ver}@{sha}" if sha else ver


def _app_key(meta: dict) -> str:
    return meta.get("frontmostBundleID") or "(unknown)"


def _first_segment_lag_ms(meta: dict, segs: list[dict]) -> float | None:
    """Wall-clock time between the first segment's audio end and when its
    record was actually appended. The streaming health signal: in a healthy
    pump this is sub-second (transcribe of a 1–4 s segment finishes shortly
    after VAD's speechEnded event); in a sick pump segments accumulate and
    only flush after Fn↑, so this can run 20–30 s.
    """
    if not segs:
        return None
    try:
        started = parse_iso(meta["startedAt"])
    except (KeyError, ValueError):
        return None
    first = min(segs, key=lambda s: float(s.get("startSec", 0.0)))
    try:
        ts = parse_iso(first["timestamp"])
    except (KeyError, ValueError):
        return None
    audio_end_wall = started.timestamp() + float(first.get("endSec", 0.0))
    return (ts.timestamp() - audio_end_wall) * 1000.0


def _flush_ratio(segs: list[dict]) -> float | None:
    """Fraction of segments emitted in the EOF flush path. 0.0 = pure
    streaming; 1.0 = nothing streamed in real time, all segments came out
    after Fn↑. Returns None if no segment carries the field (pre-#B6 build).
    """
    flagged = [s for s in segs if s.get("flushTriggered") is not None]
    if not flagged:
        return None
    on = sum(1 for s in flagged if s["flushTriggered"])
    return on / len(flagged)


def _stat_block(values: list[float]) -> str:
    if not values:
        return "n=0"
    pcts = percentiles(values, ps=(50, 95, 99))
    return f"n={len(values):3d}  p50={pcts[50]:6.0f}  p95={pcts[95]:6.0f}  p99={pcts[99]:6.0f}  max={max(values):6.0f}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    p.add_argument("--by", choices=("build", "app"), default="build",
                   help="slice metric distributions by build (default) or by frontmost app")
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    keyfn = _build_key if args.by == "build" else _app_key

    # Metric buckets are per-key. Each session contributes one value to each
    # session-level bucket (chunkLagMax / pumpStallMax / firstSegLag / flushRatio)
    # and possibly multiple to per-segment buckets (lockWaitMs).
    by: dict[str, dict] = defaultdict(lambda: {
        "n": 0,
        "live_n": 0,
        "instr_n": 0,                 # has Meta.chunkLagMaxMs (#B6 instrumented)
        "first_seg_lag_ms": [],
        "flush_ratios": [],
        "chunk_lag_max_ms": [],
        "pump_stall_max_ms": [],
        "vad_process_sum_ms": [],
        "ingest_counts": [],
        "lock_wait_ms": [],
        "force_splits": 0,
        "flush_triggered": 0,
        "seg_n": 0,
        "sick_sessions": [],          # firstSegLag > 3000 ms
    })

    for sd in sessions:
        try:
            meta = load_meta(sd)
        except Exception as exc:
            print(f"  [warn] {sd.name}: meta unreadable ({exc})")
            continue
        b = by[keyfn(meta)]
        b["n"] += 1
        if meta.get("liveMode"):
            b["live_n"] += 1
        if meta.get("chunkLagMaxMs") is not None:
            b["instr_n"] += 1
            b["chunk_lag_max_ms"].append(float(meta["chunkLagMaxMs"]))
            b["pump_stall_max_ms"].append(float(meta.get("pumpStallMaxMs") or 0))
            b["vad_process_sum_ms"].append(float(meta.get("vadProcessSumMs") or 0))
            b["ingest_counts"].append(float(meta.get("ingestCount") or 0))

        segs = load_segments(sd)
        if segs:
            lag = _first_segment_lag_ms(meta, segs)
            if lag is not None:
                b["first_seg_lag_ms"].append(lag)
                if lag > 3000:
                    b["sick_sessions"].append((sd.name, lag, meta.get("totalAudioSec")))
            ratio = _flush_ratio(segs)
            if ratio is not None:
                b["flush_ratios"].append(ratio)
            for s in segs:
                b["seg_n"] += 1
                if (lw := s.get("lockWaitMs")) is not None:
                    b["lock_wait_ms"].append(float(lw))
                if s.get("forceSplit"):
                    b["force_splits"] += 1
                if s.get("flushTriggered"):
                    b["flush_triggered"] += 1

    print(f"Sliced by: {args.by}")
    print()
    for key in sorted(by.keys()):
        b = by[key]
        if b["n"] == 0:
            continue
        print(f"=== {key} ===")
        print(f"  sessions:   {b['n']} ({b['live_n']} live)   instrumented: {b['instr_n']}")
        if b["first_seg_lag_ms"]:
            print(f"  firstSegLag (wall after audio[seg.endSec]):  {_stat_block(b['first_seg_lag_ms'])} ms")
            print(f"    ← healthy < 1000 ms; > 3000 ms = streaming wasn't streaming")
        if b["flush_ratios"]:
            avg = sum(b["flush_ratios"]) / len(b["flush_ratios"])
            full_flush = sum(1 for r in b["flush_ratios"] if r == 1.0)
            print(f"  flushRatio (segments emitted in EOF flush): mean={avg:.2f}  100%-flush sessions={full_flush}/{len(b['flush_ratios'])}")
        if b["chunk_lag_max_ms"]:
            print(f"  chunkLagMax (per-session):    {_stat_block(b['chunk_lag_max_ms'])} ms   ← AsyncStream queue residency")
            print(f"  pumpStallMax (per-session):   {_stat_block(b['pump_stall_max_ms'])} ms   ← longest gap between drains")
            print(f"  vadProcessSum (per-session):  {_stat_block(b['vad_process_sum_ms'])} ms   ← session-total VAD cost")
        if b["lock_wait_ms"]:
            print(f"  lockWait (per-segment):       {_stat_block(b['lock_wait_ms'])} ms   ← time waiting for transcribeLock")
        if b["seg_n"]:
            fs_pct = 100 * b["force_splits"] / b["seg_n"]
            ft_pct = 100 * b["flush_triggered"] / b["seg_n"]
            print(f"  segments:   {b['seg_n']}    forceSplit={b['force_splits']} ({fs_pct:.0f}%)    flushTriggered={b['flush_triggered']} ({ft_pct:.0f}%)")
        if b["sick_sessions"]:
            print(f"  sick sessions (firstSegLag > 3 s):")
            for name, lag, audio in sorted(b["sick_sessions"], key=lambda x: -x[1])[:5]:
                audio_str = f"{audio:.1f}s" if audio else "?"
                print(f"    {name}  firstSegLag={lag:6.0f}ms  audio={audio_str}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
