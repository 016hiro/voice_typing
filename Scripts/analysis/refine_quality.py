#!/usr/bin/env python3
"""LLM refine I/O quality + latency analysis (cloud vs local).

Reads `refines.jsonl` (v0.6.3 #R8) — one record per `LLMRefining.refine(...)`
call with input / output / mode / backend / latency / glossary / profile
snippet. Answers the v0.6.3 dogfood question "is local Qwen3.5-4B refiner
quality close enough to cloud to make Local the default?" without needing
any new instrumentation — just runs over existing capture data.

Usage:
  python3 refine_quality.py <capture-root-or-single-session>
  python3 refine_quality.py <root> --sample 10            # print sample I/O pairs
  python3 refine_quality.py <root> --sample 10 --seed 42  # reproducible

Schema: ../../docs/debug-captures.md (RefineRecord block).
"""

from __future__ import annotations

import argparse
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

from _common import fmt_ms, fmt_pct, iter_sessions, load_meta, load_refines, percentiles


def _ratio_bucket(ratio: float) -> str:
    # ±5% counts as "no length change"; v0.7.0 streaming flush boundaries
    # plus stripQuotesAndCode trimming routinely move output by 1-2 chars
    # without semantic edit, so a flat equality test would underreport.
    if ratio < 0.95:
        return "shortened"
    if ratio > 1.05:
        return "expanded"
    return "identical"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    p.add_argument(
        "--sample",
        type=int,
        default=0,
        help="Print N sample (input → output) pairs per backend at the end.",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Seed for --sample so reviewers can reproduce a sampled set.",
    )
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    # Per-call buckets (one entry per refine call across the whole capture).
    by_backend_ms: defaultdict[str, list[float]] = defaultdict(list)
    by_backend_ratio: defaultdict[str, list[float]] = defaultdict(list)
    by_backend_ratio_bucket: defaultdict[str, Counter] = defaultdict(Counter)
    by_mode_backend: defaultdict[str, Counter] = defaultdict(Counter)
    glossary_used = 0
    snippet_used = 0
    total_calls = 0
    sessions_with_refines = 0

    # Per-backend sample buffers for --sample at the end. We keep the raw
    # (input, output) tuples and let random.sample() pull at print time.
    samples_by_backend: defaultdict[str, list[tuple[str, str, str]]] = defaultdict(list)

    # Sessions that contain BOTH backends are A/B candidates: same user,
    # same hardware, same input distribution → useful for hand comparison.
    ab_sessions: list[tuple[str, Counter]] = []

    for sd in sessions:
        try:
            _ = load_meta(sd)
        except Exception as e:
            print(f"  [warn] {sd.name}: meta.json unreadable ({e})")
            continue
        refines = load_refines(sd)
        if not refines:
            continue
        sessions_with_refines += 1

        per_session_backends: Counter = Counter()
        for r in refines:
            backend = r.get("backend", "unknown")
            mode = r.get("mode", "unknown")
            ms = r.get("latencyMs")
            inp = r.get("input", "")
            out = r.get("output", "")
            glossary = r.get("glossary")
            snippet = r.get("profileSnippet")

            total_calls += 1
            per_session_backends[backend] += 1
            by_mode_backend[mode][backend] += 1
            if isinstance(ms, (int, float)) and ms >= 0:
                by_backend_ms[backend].append(float(ms))
            if inp:
                ratio = len(out) / len(inp)
                by_backend_ratio[backend].append(ratio)
                by_backend_ratio_bucket[backend][_ratio_bucket(ratio)] += 1
            if glossary and str(glossary).strip():
                glossary_used += 1
            if snippet and str(snippet).strip():
                snippet_used += 1
            samples_by_backend[backend].append((sd.name, inp, out))

        if len(per_session_backends) > 1:
            ab_sessions.append((sd.name, per_session_backends))

    if total_calls == 0:
        print(f"No refine activity in {len(sessions)} session(s).")
        print("(Refines only land when state.debugCaptureEnabled was on AND mode != .off.)")
        return 0

    print(
        f"Refine calls: {total_calls} across {sessions_with_refines} / {len(sessions)} sessions "
        f"({fmt_pct(sessions_with_refines, len(sessions))})"
    )
    print()

    print("Per-backend latency:")
    for backend in sorted(by_backend_ms.keys()):
        ms = by_backend_ms[backend]
        if not ms:
            continue
        pcts = percentiles(ms, ps=(50, 95, 99))
        print(
            f"  {backend:<8} n={len(ms):>4}  "
            f"p50={fmt_ms(pcts[50])}  p95={fmt_ms(pcts[95])}  p99={fmt_ms(pcts[99])}  "
            f"max={fmt_ms(max(ms))}"
        )
    print()

    print("Per-mode call counts (cloud / local split):")
    for mode in sorted(by_mode_backend.keys()):
        per_b = by_mode_backend[mode]
        total = sum(per_b.values())
        breakdown = "  ".join(f"{b}={n}" for b, n in sorted(per_b.items()))
        print(f"  {mode:<14} n={total:>4}    {breakdown}")
    print()

    # Length-ratio buckets answer "is the model rewriting more aggressively
    # than expected?" Aggressive mode legitimately expands (lists, smoothing);
    # conservative/light should mostly land in `identical`.
    print("Output/input length ratio (cloud vs local):")
    for backend in sorted(by_backend_ratio.keys()):
        ratios = by_backend_ratio[backend]
        if not ratios:
            continue
        pcts = percentiles(ratios, ps=(50, 95))
        bucket = by_backend_ratio_bucket[backend]
        n = sum(bucket.values())
        s = bucket.get("shortened", 0)
        i = bucket.get("identical", 0)
        e = bucket.get("expanded", 0)
        print(
            f"  {backend:<8} p50={pcts[50]:.2f}  p95={pcts[95]:.2f}    "
            f"shortened={fmt_pct(s, n)}  identical={fmt_pct(i, n)}  expanded={fmt_pct(e, n)}"
        )
    print()

    print(
        f"Glossary injected:        {glossary_used} / {total_calls} "
        f"({fmt_pct(glossary_used, total_calls)})"
    )
    print(
        f"Profile snippet injected: {snippet_used} / {total_calls} "
        f"({fmt_pct(snippet_used, total_calls)})"
    )

    if ab_sessions:
        print()
        print(f"A/B candidate sessions (cloud + local in same session): {len(ab_sessions)}")
        # Cap output so capture roots with hundreds of sessions don't drown.
        for name, counts in ab_sessions[:10]:
            breakdown = "  ".join(f"{b}={n}" for b, n in sorted(counts.items()))
            print(f"  {name}    {breakdown}")
        if len(ab_sessions) > 10:
            print(f"  ... ({len(ab_sessions) - 10} more)")

    if args.sample > 0:
        if args.seed is not None:
            random.seed(args.seed)
        print()
        print(f"Sample I/O pairs (n={args.sample} per backend):")
        for backend in sorted(samples_by_backend.keys()):
            pool = samples_by_backend[backend]
            k = min(args.sample, len(pool))
            picks = random.sample(pool, k) if k < len(pool) else pool
            print(f"  --- {backend} (showing {k} of {len(pool)}) ---")
            for sname, inp, out in picks:
                same = "·" if inp == out else "→"
                print(f"  [{sname}]")
                print(f"    in : {inp}")
                print(f"    out{same} {out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
