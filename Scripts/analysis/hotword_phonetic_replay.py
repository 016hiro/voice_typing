#!/usr/bin/env python3
"""Hotword phonetic guard prototype — Layer 2 for v0.8.0 #S1.

Layer 1 (existing): substring match against `term` and `pronunciationHints`
via `GlossaryBuilder.matchedEntryIDs`. Cheap, exact, but requires user to
enumerate every ASR mishearing — which they can't.

Layer 2 (this script): toneless-pinyin / lowercase-latin normalization +
sliding-window Levenshtein. Catches the "I said 'Qwen' but ASR wrote
'曲文' and the user never filled that as a hint" case algorithmically.

Goal of this replay: simulate Layer 2 on existing dogfood `refines.jsonl`
+ current `dictionary.json`, and quantify

  - how many `variant_c` skips get correctly *blocked* (would have been
    user-visible damage)
  - how many `variant_c` skips get *unnecessarily* blocked (no quality
    win — just costs ~1.5s of refine the user could have saved)

This trade-off — FN (skip lost = wasted refine) is fine, FP (refine lost
= user sees uncleaned hotword) is not — is the design constraint the user
set in this iteration.

Run:
  uv run hotword_phonetic_replay.py <capture-root> <dictionary.json>
  uv run hotword_phonetic_replay.py <capture-root> <dict.json> --threshold 0.3
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Optional

import jieba
import pypinyin

# Suppress jieba's first-call dict-build log noise on stderr.
jieba.setLogLevel(60)

from _common import iter_sessions, load_refines


# --- Normalization -----------------------------------------------------------

_CJK_RANGE = (0x4E00, 0x9FFF)


def _is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return _CJK_RANGE[0] <= cp <= _CJK_RANGE[1]


def normalize_form(s: str) -> str:
    """Flatten to phonetic latin form.

    - CJK char → toneless pinyin syllable (no separator)
    - ASCII letter → lowercase
    - ASCII digit → kept as-is (so 'e2e', 'k8s', 'h264' survive)
    - everything else dropped
    """
    parts: list[str] = []
    for ch in s:
        if ch.isascii():
            if ch.isalpha():
                parts.append(ch.lower())
            elif ch.isdigit():
                parts.append(ch)
        elif _is_cjk(ch):
            py = pypinyin.lazy_pinyin(ch, style=pypinyin.Style.NORMAL)
            if py:
                parts.append(py[0])
    return "".join(parts)


def tokenize(text: str) -> list[str]:
    """jieba word-level segmentation for Chinese, English passes through.

    Filters empty / whitespace-only tokens. Cuts like:
      "之前应该是有对数字..."  → ["之前", "应该", "是", "有", "对", "数字", ...]
      "想一想，我们应该把之前的 prompt 再" → ["想", "一", "想", "，", "我们", "应该", "把", "之前", "的", " ", "prompt", " ", "再"]
    so single-char function words / punct / spaces all get filtered downstream
    by min_form_len.
    """
    return [t for t in jieba.lcut(text) if t.strip()]


# --- Levenshtein -------------------------------------------------------------

def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    if len(a) > len(b):
        a, b = b, a
    prev = list(range(len(a) + 1))
    for i, cb in enumerate(b, start=1):
        cur = [i]
        for j, ca in enumerate(a, start=1):
            cost = 0 if ca == cb else 1
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1]


# --- Phonetic guard ----------------------------------------------------------

def phonetic_match(
    input_text: str,
    hotwords: list[dict],
    threshold: float,
    min_form_len: int = 4,
    max_ngram: int = 3,
) -> Optional[tuple[str, str, str, int]]:
    """Returns (matched_term, matched_variant, matched_source, edit_distance)
    on first hit, or None.

    Strategy:
      1. jieba-tokenize input into word tokens
      2. Build candidate forms: each token's pinyin/latin form, plus 2- and 3-gram
         concatenations of consecutive tokens. This handles two cases:
           - "原文" (one jieba word) → form "yuanwen" → matches Chinese hotwords
             at word granularity, avoids cross-word false positives like
             "之前应该" → "qianyin" matching "千问"="qianwen"
           - "曲文" (jieba splits → ["曲","文"]) → 2-gram form "quwen" → can
             still match "Qwen"="qwen" across the cross-script boundary
      3. Require candidate form length >= min_form_len (default 4): single Chinese
         function-word characters like 文/问/温/的 have 2-3 char pinyin that
         spuriously match short English hotwords; filtering them out kills the
         noise floor while n-grams recover legitimate compound matches.
      4. For each (candidate, variant), check substring then Levenshtein
         d / L_variant <= threshold.
    """
    tokens = tokenize(input_text)
    if not tokens:
        return None

    # Build candidate forms (form_str, source_str) — source for diagnostic.
    candidates: list[tuple[str, str]] = []
    for n in range(1, max_ngram + 1):
        for i in range(len(tokens) - n + 1):
            source = "".join(tokens[i : i + n])
            form = normalize_form(source)
            if len(form) >= min_form_len:
                candidates.append((form, source))

    if not candidates:
        return None

    for hw in hotwords:
        for variant in [hw["term"]] + list(hw.get("pronunciationHints", [])):
            v_form = normalize_form(variant)
            if len(v_form) < 3:
                continue
            L = len(v_form)
            allowed = threshold * L
            for form, source in candidates:
                # 1. exact substring (e.g., "qwen" in "qwenstuff")
                if v_form in form:
                    return (hw["term"], variant, source, 0)
                # 2. fuzzy edit distance, candidate vs variant directly
                if abs(len(form) - L) > allowed:
                    continue
                d = levenshtein(form, v_form)
                if d <= allowed:
                    return (hw["term"], variant, source, d)
    return None


# --- Variant C (skip heuristic copy for in-script replay) --------------------

_ZH_FILLER = ["啊", "嗯", "呃", "唉", "哦", "嘛", "呢", "那个", "就是", "这个"]
_EN_FILLER_RE = re.compile(
    r"\b(?:um+|uh+|er+|hmm+|like|you\s+know|kinda|sorta|basically|literally|i\s+mean)\b",
    re.IGNORECASE,
)
_STUTTER_ZH_RE = re.compile(r"(.{1,2})\1")
_STUTTER_EN_RE = re.compile(r"\b(\w+)\s+\1\b", re.IGNORECASE)
_ZH_NUM_RE = re.compile(r"[零一二三四五六七八九十百千万亿点]{2,}")
_CODESWITCH_RE = re.compile(r"[一-鿿][A-Za-z]|[A-Za-z][一-鿿]")
_PUNCT_ENG_RE = re.compile(r"[A-Za-z0-9][。？！]|[。？！][A-Za-z0-9]")


def variant_c_skip(inp: str, length_threshold: int = 40) -> bool:
    if not inp.strip():
        return True
    if len(inp) >= length_threshold:
        return False
    for f in _ZH_FILLER:
        if f in inp:
            return False
    if _EN_FILLER_RE.search(inp):
        return False
    if _STUTTER_ZH_RE.search(inp):
        return False
    if _STUTTER_EN_RE.search(inp):
        return False
    if _ZH_NUM_RE.search(inp):
        return False
    if _CODESWITCH_RE.search(inp):
        return False
    if _PUNCT_ENG_RE.search(inp):
        return False
    return True


def is_noop(inp: str, out: str) -> bool:
    a = unicodedata.normalize("NFC", re.sub(r"\s+", " ", inp).strip())
    b = unicodedata.normalize("NFC", re.sub(r"\s+", " ", out).strip())
    return a == b


# --- Main --------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("captures", type=Path, help="capture root or single session dir")
    p.add_argument("dictionary", type=Path, help="path to dictionary.json")
    p.add_argument("--threshold", type=float, default=0.3,
                   help="d/L Levenshtein ratio threshold (default 0.3)")
    p.add_argument("--length-threshold", type=int, default=40,
                   help="variant C length cutoff (default 40)")
    p.add_argument("--sample", type=int, default=8,
                   help="print N example matches per category (default 8)")
    args = p.parse_args()

    # Load dictionary
    with open(args.dictionary, "rb") as f:
        dict_blob = json.load(f)
    hotwords = dict_blob.get("entries", [])
    print(f"Loaded {len(hotwords)} hotword entries:")
    for hw in hotwords:
        hints = hw.get("pronunciationHints", []) or []
        forms = [hw["term"]] + hints
        norms = " / ".join(f"{f}→{normalize_form(f)}" for f in forms if normalize_form(f))
        print(f"  {hw['term']:<14} {norms}")
    print()

    # Load all refine records
    records: list[dict] = []
    for sd in iter_sessions(args.captures):
        for r in load_refines(sd):
            records.append(r)
    records.sort(key=lambda r: r.get("timestamp", ""))
    if not records:
        print(f"No refines found under {args.captures}")
        return 1

    # Replay: track (variant_c_skip, phonetic_hit, noop) for each record
    rows = []
    for r in records:
        inp = r.get("input", "")
        out = r.get("output", "")
        latency = r.get("latencyMs", 0) or 0
        skip_c = variant_c_skip(inp, args.length_threshold)
        hit = phonetic_match(inp, hotwords, args.threshold) if skip_c else None
        rows.append({
            "input": inp, "output": out, "latency": latency,
            "skip_c": skip_c, "phonetic_hit": hit,
            "noop": is_noop(inp, out),
        })

    # ---- Variant C baseline ----
    c_skipped = [r for r in rows if r["skip_c"]]
    c_tp = sum(1 for r in c_skipped if r["noop"])
    c_fp = sum(1 for r in c_skipped if not r["noop"])
    print("=" * 70)
    print(f"Baseline: variant C (no phonetic guard)")
    print("=" * 70)
    print(f"  skipped: {len(c_skipped)}/{len(rows)}  TP={c_tp} FP={c_fp}")
    print(f"  precision: {c_tp / max(len(c_skipped),1) * 100:.1f}%")
    print()

    # ---- Variant C + phonetic guard ----
    cp_skipped = [r for r in rows if r["skip_c"] and r["phonetic_hit"] is None]
    cp_blocked_by_phonetic = [r for r in rows if r["skip_c"] and r["phonetic_hit"]]
    cp_tp = sum(1 for r in cp_skipped if r["noop"])
    cp_fp = sum(1 for r in cp_skipped if not r["noop"])
    print("=" * 70)
    print(f"Variant C + phonetic guard (threshold {args.threshold})")
    print("=" * 70)
    print(f"  skipped: {len(cp_skipped)}/{len(rows)}  TP={cp_tp} FP={cp_fp}")
    print(f"  precision: {cp_tp / max(len(cp_skipped),1) * 100:.1f}%")
    print(f"  blocked by phonetic guard: {len(cp_blocked_by_phonetic)}")
    print()

    # ---- The interesting breakdown ----
    # Among records the phonetic guard blocked (= would have been C skips):
    #   - the ones that were actually FP under C (= damage avoided) ← THE WIN
    #   - the ones that were actually TP under C (= unnecessary block) ← THE COST
    fp_recovered = [r for r in cp_blocked_by_phonetic if not r["noop"]]
    tp_lost = [r for r in cp_blocked_by_phonetic if r["noop"]]
    extra_refine_ms = sum(r["latency"] for r in tp_lost)
    print("=" * 70)
    print("Phonetic guard impact breakdown")
    print("=" * 70)
    print(f"  FPs recovered (skip → refine, was real damage avoided): {len(fp_recovered)}")
    print(f"  TPs lost (skip → refine, was a fine skip): {len(tp_lost)}")
    print(f"  cost: +{extra_refine_ms / 1000:.1f}s LLM time on lost TPs")
    print()

    if fp_recovered:
        print(f"--- FPs recovered (variant C would damage, phonetic catches) — showing {min(args.sample, len(fp_recovered))} of {len(fp_recovered)}:")
        for r in fp_recovered[:args.sample]:
            term, variant, window, d = r["phonetic_hit"]
            print(f"  in : {r['input']}")
            print(f"  out: {r['output']}")
            print(f"  hit: hotword={term!r} variant={variant!r} matched window={window!r} d={d}")
            print()

    if tp_lost:
        print(f"--- TPs lost (was correct skip, phonetic unnecessarily blocked) — showing {min(args.sample, len(tp_lost))} of {len(tp_lost)}:")
        for r in tp_lost[:args.sample]:
            term, variant, window, d = r["phonetic_hit"]
            print(f"  in : {r['input']}  [noop, latency was {r['latency']}ms]")
            print(f"  hit: hotword={term!r} variant={variant!r} matched window={window!r} d={d}")
            print()

    # ---- Phonetic-only signal across ALL records (not just C-skipped) ----
    # Useful to see: how often does ASR put a hotword-shaped phonetic blob in
    # the input, regardless of whether C wanted to skip?
    all_hits = 0
    fp_potential = 0  # records where input → refine changed text AND phonetic hits
    for r in rows:
        if not r["skip_c"]:
            h = phonetic_match(r["input"], hotwords, args.threshold)
            if h:
                all_hits += 1
                if not r["noop"]:
                    fp_potential += 1
    total_phonetic_hits = all_hits + len(cp_blocked_by_phonetic)
    print("=" * 70)
    print("Phonetic match prevalence across ALL records (sanity check)")
    print("=" * 70)
    print(f"  records where input has a phonetic hotword hit: {total_phonetic_hits}/{len(rows)} ({total_phonetic_hits/len(rows)*100:.1f}%)")
    print(f"    of which input != output (refine actually fixed something): {fp_potential + len(fp_recovered)}/{total_phonetic_hits}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
