#!/usr/bin/env python3
"""Skip-refine replay — joint analysis for v0.8.0 #S1 (rule-based heuristic)
and #S2 (memoization cache).

Reads `refines.jsonl` across sessions, replays each refine call through two
parallel skip mechanisms, and reports confusion matrix + saved latency for
each — plus their combined coverage. Lets us pick thresholds before writing
either mechanism in Swift.

Skip mechanisms under evaluation:

  #S1 rule heuristic
    Predict skip when input has *no markers* AND length < threshold.
    Markers: filler words (zh+en), stutter, Chinese number string,
    unspaced code-switch. Cost of false positive (skip when refine would
    have changed text) = user loses a fix.

  #S2 memoization cache
    Key = (normalize(input), mode, backend). On hit with cached "noop",
    we would skip the LLM call. Records are processed in chronological
    order across sessions so cache state evolves as it would in production.

Usage:
  python3 skip_refine_replay.py <capture-root>
  python3 skip_refine_replay.py <root> --length-threshold 40
  python3 skip_refine_replay.py <root> --cache-max-input-chars 30
  python3 skip_refine_replay.py <root> --sample-mistakes 5

Schema: ../../docs/debug-captures.md (RefineRecord block).
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

from _common import (
    fmt_ms,
    fmt_pct,
    iter_sessions,
    load_meta,
    load_refines,
    parse_iso,
    percentiles,
)


# --- Ground truth ------------------------------------------------------------

def _normalize_for_compare(s: str) -> str:
    """Collapse whitespace, NFC unicode, strip — what a user would consider
    'same text'. Trailing space / NFC differences are not visible noop wins
    we want to count as fixes."""
    s = unicodedata.normalize("NFC", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def is_noop(inp: str, out: str) -> bool:
    return _normalize_for_compare(inp) == _normalize_for_compare(out)


# --- #S1 rule heuristic ------------------------------------------------------

# Filler markers. Chinese list intentionally favors *false negatives*
# (let things through to refine) over false positives — "那个/这个/就是"
# also appear as legitimate determiners. The whole point of #S1 is to skip
# *only* unambiguously clean short input.
_ZH_FILLER = ["啊", "嗯", "呃", "唉", "哦", "嘛", "呢", "那个", "就是", "这个"]
_EN_FILLER_RE = re.compile(
    r"\b(?:um+|uh+|er+|hmm+|like|you\s+know|kinda|sorta|basically|literally|i\s+mean)\b",
    re.IGNORECASE,
)
# Stutter: repeated 1-2 char unit (Chinese 我我 / 这个这个 / English 'the the').
_STUTTER_ZH_RE = re.compile(r"(.{1,2})\1")
_STUTTER_EN_RE = re.compile(r"\b(\w+)\s+\1\b", re.IGNORECASE)
# Chinese number string (≥2 consecutive number chars) — these often need
# digit normalization that ASR misses.
_ZH_NUM_RE = re.compile(r"[零一二三四五六七八九十百千万亿点]{2,}")
# Code-switch without space at the boundary: refine commonly inserts spaces.
_CODESWITCH_RE = re.compile(r"[一-鿿][A-Za-z]|[A-Za-z][一-鿿]")


def s1_predict_skip(inp: str, length_threshold: int) -> tuple[bool, str | None]:
    """Returns (would_skip, blocking_marker). When `would_skip` is True the
    blocking_marker is None. When False, it's a string tag explaining why
    we declined to skip (useful for debugging false negatives)."""
    if not inp.strip():
        return (True, None)  # empty input is trivially skippable

    if len(inp) >= length_threshold:
        return (False, f"len>={length_threshold}")

    for f in _ZH_FILLER:
        if f in inp:
            return (False, f"zh_filler:{f}")

    if _EN_FILLER_RE.search(inp):
        return (False, "en_filler")

    if _STUTTER_ZH_RE.search(inp):
        return (False, "stutter_zh")

    if _STUTTER_EN_RE.search(inp):
        return (False, "stutter_en")

    if _ZH_NUM_RE.search(inp):
        return (False, "zh_number")

    if _CODESWITCH_RE.search(inp):
        return (False, "codeswitch_unspaced")

    return (True, None)


# --- #S2 memoization simulation ----------------------------------------------

def s2_cache_key(inp: str, mode: str, backend: str) -> str:
    return f"{_normalize_for_compare(inp).lower()}|{mode}|{backend}"


# --- Replay ------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", type=Path, help="capture root or single session dir")
    p.add_argument(
        "--length-threshold",
        type=int,
        default=40,
        help="#S1: skip only when input length < N chars (default 40).",
    )
    p.add_argument(
        "--cache-max-input-chars",
        type=int,
        default=60,
        help="#S2: don't cache inputs longer than N chars (default 60).",
    )
    p.add_argument(
        "--cache-max-entries",
        type=int,
        default=2000,
        help="#S2: cache eviction cap (LRU). Default 2000.",
    )
    p.add_argument(
        "--sample-mistakes",
        type=int,
        default=0,
        help="Print N example #S1 false positives + false negatives at the end.",
    )
    args = p.parse_args()

    sessions = list(iter_sessions(args.path))
    if not sessions:
        print(f"No sessions found under {args.path}")
        return 1

    # Collect every refine record across all sessions in chronological order.
    records: list[dict] = []
    sessions_with_refines = 0
    for sd in sessions:
        try:
            _ = load_meta(sd)
        except Exception:
            continue
        refines = load_refines(sd)
        if not refines:
            continue
        sessions_with_refines += 1
        for r in refines:
            r["_session"] = sd.name
            records.append(r)
    records.sort(key=lambda r: r.get("timestamp", ""))

    if not records:
        print(f"No refine activity in {len(sessions)} session(s).")
        return 0

    total = len(records)
    noop_count = sum(1 for r in records if is_noop(r.get("input", ""), r.get("output", "")))
    print(
        f"Refine calls: {total} across {sessions_with_refines} / {len(sessions)} sessions  "
        f"({fmt_pct(sessions_with_refines, len(sessions))})"
    )
    print(f"Actual no-op rate: {noop_count}/{total} ({fmt_pct(noop_count, total)})")
    print()

    # ---- #S1 confusion matrix ----
    s1_tp = s1_fp = s1_fn = s1_tn = 0
    s1_saved_ms = 0
    s1_lost_fixes: list[dict] = []
    s1_missed_noops: list[dict] = []
    s1_blocker_counts: Counter = Counter()

    # ---- #S2 simulation ----
    cache: dict[str, str] = {}  # key → "noop" or cached output
    cache_lru: list[str] = []   # ordered list of keys for LRU eviction
    s2_hits = s2_misses = 0
    s2_skip_short_only = 0
    s2_saved_ms = 0
    s2_long_skipped_from_cache = 0  # records whose input was too long to cache

    # ---- Combined: skip if EITHER mechanism would skip ----
    combined_skip = 0
    combined_saved_ms = 0

    for r in records:
        inp = r.get("input", "")
        out = r.get("output", "")
        mode = r.get("mode", "unknown")
        backend = r.get("backend", "unknown")
        latency = r.get("latencyMs", 0) or 0
        truth_noop = is_noop(inp, out)

        # ---- #S1 ----
        s1_would_skip, blocker = s1_predict_skip(inp, args.length_threshold)
        if not s1_would_skip and blocker:
            s1_blocker_counts[blocker] += 1
        if s1_would_skip and truth_noop:
            s1_tp += 1
            s1_saved_ms += latency
        elif s1_would_skip and not truth_noop:
            s1_fp += 1
            if len(s1_lost_fixes) < 50:
                s1_lost_fixes.append(r)
        elif not s1_would_skip and truth_noop:
            s1_fn += 1
            if len(s1_missed_noops) < 50:
                s1_missed_noops.append(r)
        else:
            s1_tn += 1

        # ---- #S2 ----
        if len(inp) > args.cache_max_input_chars:
            s2_long_skipped_from_cache += 1
            s2_would_skip = False
        else:
            key = s2_cache_key(inp, mode, backend)
            if key in cache and cache[key] == "noop":
                s2_hits += 1
                s2_would_skip = True
                s2_saved_ms += latency
                # refresh LRU
                cache_lru.remove(key)
                cache_lru.append(key)
            else:
                s2_misses += 1
                s2_would_skip = False
                # Write to cache *after* observing outcome (production behavior).
                value = "noop" if truth_noop else out
                if key in cache:
                    cache_lru.remove(key)
                cache[key] = value
                cache_lru.append(key)
                # LRU evict
                while len(cache_lru) > args.cache_max_entries:
                    drop = cache_lru.pop(0)
                    cache.pop(drop, None)

        # ---- Combined ----
        if s1_would_skip or s2_would_skip:
            combined_skip += 1
            combined_saved_ms += latency

    # ---- #S1 report ----
    s1_predicted_skip = s1_tp + s1_fp
    s1_predicted_refine = s1_fn + s1_tn
    print("=" * 70)
    print(f"#S1 rule heuristic (length < {args.length_threshold})")
    print("=" * 70)
    print(f"  Predicted skip:   {s1_predicted_skip}/{total} ({fmt_pct(s1_predicted_skip, total)})")
    print(f"    TP (correct skip):       {s1_tp}")
    print(f"    FP (lost a fix):         {s1_fp}  ← user-visible damage")
    print(f"  Predicted refine: {s1_predicted_refine}/{total} ({fmt_pct(s1_predicted_refine, total)})")
    print(f"    FN (missed noop):        {s1_fn}")
    print(f"    TN (correct refine):     {s1_tn}")
    print(f"  Precision (skip): {fmt_pct(s1_tp, s1_predicted_skip)}  (of skipped, fraction that was truly noop)")
    print(f"  Recall    (skip): {fmt_pct(s1_tp, noop_count)}  (of all noops, fraction caught)")
    print(f"  Time saved (sum latencyMs of TP): {s1_saved_ms/1000:.1f}s "
          f"avg {s1_saved_ms / max(s1_tp,1):.0f}ms per TP")
    if s1_blocker_counts:
        print(f"  Top reasons we declined to skip (FN + TN):")
        for tag, n in s1_blocker_counts.most_common(8):
            print(f"    {tag:<24} {n}")
    print()

    # ---- #S2 report ----
    s2_attempted = s2_hits + s2_misses  # records where caching was tried
    print("=" * 70)
    print(f"#S2 memoization cache (cap {args.cache_max_input_chars} chars, max {args.cache_max_entries} entries)")
    print("=" * 70)
    print(f"  Long input bypassed cache:  {s2_long_skipped_from_cache}/{total} "
          f"({fmt_pct(s2_long_skipped_from_cache, total)})")
    print(f"  Cache attempts:             {s2_attempted}")
    print(f"  Cache hits:                 {s2_hits}/{s2_attempted} ({fmt_pct(s2_hits, s2_attempted)})")
    print(f"  Cache misses (LLM ran):     {s2_misses}/{s2_attempted}")
    print(f"  Cache size at end:          {len(cache)} entries")
    print(f"  Time saved (sum latencyMs of hits): {s2_saved_ms/1000:.1f}s "
          f"avg {s2_saved_ms / max(s2_hits,1):.0f}ms per hit")
    # #S2 false positives = hit returned "noop" but actual outcome was a fix.
    # By construction we only cache as "noop" when previous run was noop, so
    # a FP happens only when the same input refines differently this time —
    # rare for short inputs in a single mode/backend, but worth knowing.
    print()

    # ---- Combined ----
    print("=" * 70)
    print("Combined (#S1 OR #S2 would skip)")
    print("=" * 70)
    print(f"  Total skipped:      {combined_skip}/{total} ({fmt_pct(combined_skip, total)})")
    print(f"  Time saved:         {combined_saved_ms/1000:.1f}s "
          f"({fmt_pct(combined_saved_ms, sum((r.get('latencyMs',0) or 0) for r in records))} of total LLM time)")
    total_llm_ms = sum((r.get("latencyMs", 0) or 0) for r in records)
    if total_llm_ms:
        print(f"  Total LLM wall-clock observed: {total_llm_ms/1000:.1f}s")
    print()

    # ---- Sample mistakes ----
    if args.sample_mistakes > 0:
        n = args.sample_mistakes
        if s1_lost_fixes:
            print(f"#S1 FP samples (would skip but refine actually changed text) — {min(n, len(s1_lost_fixes))} of {len(s1_lost_fixes)}:")
            for r in s1_lost_fixes[:n]:
                print(f"  in : {r.get('input','')}")
                print(f"  out: {r.get('output','')}  [{r.get('mode')}/{r.get('backend')}]")
            print()
        if s1_missed_noops:
            print(f"#S1 FN samples (refined but was noop) — {min(n, len(s1_missed_noops))} of {len(s1_missed_noops)}:")
            for r in s1_missed_noops[:n]:
                print(f"  in : {r.get('input','')}  [{r.get('mode')}/{r.get('backend')}]")
            print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
