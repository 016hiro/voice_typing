"""Shared helpers for the v0.5.2 debug-capture analysis scripts.

Schema reference: ../../docs/debug-captures.md.

Only Python 3.8+ stdlib. No third-party deps. Each consumer script imports
just the helpers it needs and writes its own argparse / output formatting.
"""

from __future__ import annotations

import json
import os
import re
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator


# Session directory names look like `2026-04-21_18-30-42_a1b2c3d4`.
# `meta.json` presence is the authoritative discriminator (lets us survive a
# user dropping a single session into a temp folder); the regex is a cheap
# pre-filter when scanning a populated capture root.
_SESSION_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[0-9a-f]{8}$")


def is_session_dir(path: Path) -> bool:
    """A directory is a session dir if it has a meta.json. Name matching is
    only a fast-path filter — the meta.json check is what counts."""
    return path.is_dir() and (path / "meta.json").is_file()


def iter_sessions(target: Path) -> Iterator[Path]:
    """Yield session directories.

    Two accepted shapes for `target`:
      1. capture root (`debug-captures/`) — yield every child that looks like a session
      2. single session directory — yield it and stop

    Order is lexicographic, which equals chronological because session dir
    names start with ISO-ish local timestamps.
    """
    target = target.expanduser().resolve()
    if not target.exists():
        raise FileNotFoundError(f"Path does not exist: {target}")

    if is_session_dir(target):
        yield target
        return

    if not target.is_dir():
        raise NotADirectoryError(f"Not a directory: {target}")

    for child in sorted(target.iterdir()):
        if _SESSION_DIR_RE.match(child.name) and is_session_dir(child):
            yield child


def load_meta(session_dir: Path) -> dict:
    """Read meta.json. Caller is expected to have a session dir from
    `iter_sessions` so the file exists; we don't swallow errors here so a
    corrupt file blows up loudly with the path in the trace."""
    with (session_dir / "meta.json").open("r", encoding="utf-8") as f:
        return json.load(f)


def _load_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    out: list[dict] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, raw in enumerate(f, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                out.append(json.loads(raw))
            except json.JSONDecodeError as e:
                # One bad line shouldn't kill an analysis run across hundreds
                # of sessions. Surface enough info to find the offender.
                print(f"  [warn] {path}:{line_no} bad JSON: {e}")
    return out


def load_segments(session_dir: Path) -> list[dict]:
    return _load_jsonl(session_dir / "segments.jsonl")


def load_injections(session_dir: Path) -> list[dict]:
    return _load_jsonl(session_dir / "injections.jsonl")


def parse_iso(ts: str) -> datetime:
    """Capture timestamps are emitted as `...Z` (UTC). Python 3.10 fromisoformat
    accepts that directly; 3.8/3.9 don't, so we normalize."""
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts).astimezone(timezone.utc)


def percentiles(values: Iterable[float], ps: Iterable[int] = (50, 90, 95, 99)) -> dict[int, float]:
    """Returns {p: value} for each requested percentile.

    Empty input → all NaN-equivalent (0.0). Caller should guard for "no data"
    before printing if it matters. We use the inclusive method so small samples
    behave intuitively (p100 == max).
    """
    values = sorted(values)
    if not values:
        return {p: 0.0 for p in ps}
    n = len(values)
    out: dict[int, float] = {}
    for p in ps:
        if n == 1:
            out[p] = values[0]
            continue
        # Linear interpolation between order statistics. Equivalent to
        # statistics.quantiles(method="inclusive") at the requested cut.
        rank = (p / 100) * (n - 1)
        lo = int(rank)
        hi = min(lo + 1, n - 1)
        frac = rank - lo
        out[p] = values[lo] + (values[hi] - values[lo]) * frac
    return out


def histogram_ascii(
    values: Iterable[float],
    *,
    bucket: float,
    max_bar: int = 30,
    label: str = "",
) -> str:
    """Render values into ASCII bar chart bucketed by `bucket` units.

    Returns multi-line string. Empty input → empty string.
    """
    values = list(values)
    if not values:
        return ""
    buckets: dict[int, int] = {}
    for v in values:
        idx = int(v // bucket)
        buckets[idx] = buckets.get(idx, 0) + 1
    if not buckets:
        return ""
    peak = max(buckets.values())
    lines = []
    for idx in range(min(buckets), max(buckets) + 1):
        lo = idx * bucket
        hi = lo + bucket
        count = buckets.get(idx, 0)
        bar = "█" * int(round((count / peak) * max_bar)) if peak else ""
        lines.append(f"  {label}{lo:>7.0f}-{hi:<7.0f}  {bar} {count}")
    return "\n".join(lines)


def human_bytes(n: int) -> str:
    """Mimic the Swift app's ByteCountFormatter output style — KB / MB / GB
    pivot, no decimals below 10 of the unit."""
    if n < 1024:
        return f"{n} B"
    units = ["KB", "MB", "GB", "TB"]
    val = float(n)
    for u in units:
        val /= 1024.0
        if val < 1024.0:
            if val < 10:
                return f"{val:.1f} {u}"
            return f"{val:.0f} {u}"
    return f"{val:.0f} PB"


def dir_size_bytes(path: Path) -> int:
    """Recursive on-disk size. os.walk is faster than Path.rglob for
    thousands of files (which we hit at the capture-root level)."""
    total = 0
    for dirpath, _, filenames in os.walk(path):
        for name in filenames:
            try:
                total += os.path.getsize(os.path.join(dirpath, name))
            except OSError:
                pass
    return total


def fmt_pct(num: float, den: float) -> str:
    if den <= 0:
        return "n/a"
    return f"{(num / den) * 100:.1f}%"


def fmt_ms(v: float) -> str:
    """Consistent ms formatting: integer ms unless very small."""
    if v < 1:
        return f"{v:.2f} ms"
    return f"{v:>5.0f} ms"
