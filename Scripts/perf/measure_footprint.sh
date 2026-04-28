#!/bin/bash
# Resource footprint sampler for VoiceTyping.
#
# Usage:
#   ./Scripts/perf/measure_footprint.sh <scenario_label> [duration_sec=20]
#
# Polls `ps` once per second for `duration_sec` and dumps a CSV under
# `build/perf/<scenario>_YYYYMMDD_HHMMSS.csv`. Then prints a min/avg/peak
# summary so each scenario is eyeball-able as it ends.
#
# Columns:
#   epoch, cpu_pct, rss_mb, vsz_mb, swap_used_mb
#
# RSS is the per-process resident size (real RAM held). swap_used_mb is
# system-wide via `sysctl vm.swapusage` — this is the only honest "we're
# under memory pressure" signal: when the kernel actually had to page out.
# Anything < 100 MB is normal; > 1 GB while running our app means the
# scenario is exceeding what the box can hold comfortably.
#
# RSS = resident set size (physical RAM held). VSZ = virtual size (mmap
# total — much larger; not "RAM used"). mem_pressure_pct is system-wide
# (sysctl-derived), included so we can see when scenarios push the box.
#
# For ANE / GPU utilization: open Activity Monitor → Window → GPU History
# (cmd-4) and Energy tab; macOS doesn't surface per-process ANE in CLI.

set -euo pipefail

SCENARIO="${1:?usage: measure_footprint.sh <scenario> [duration_sec]}"
DURATION="${2:-20}"
OUT_DIR="$(cd "$(dirname "$0")/../.." && pwd)/build/perf"
mkdir -p "$OUT_DIR"

PID="$(pgrep -x VoiceTyping | head -n1 || true)"
if [[ -z "$PID" ]]; then
    echo "ERROR: VoiceTyping not running. Launch the app first." >&2
    exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT="$OUT_DIR/${SCENARIO}_${TS}.csv"

echo "→ scenario=$SCENARIO pid=$PID duration=${DURATION}s out=$OUT"
echo "epoch,cpu_pct,rss_mb,vsz_mb,swap_used_mb" > "$OUT"

# `sysctl vm.swapusage` returns: total = X.YYM  used = A.BBM  free = C.DDM
# We grab "used" and convert to MB. Anything > a few hundred MB while a
# scenario is running is the signal that the box is paging — i.e., the
# scenario doesn't fit in RAM and macOS is faulting model pages back from
# the swap file.
swap_used_mb() {
    sysctl -n vm.swapusage | awk '
        match($0, /used = [0-9.]+[KMG]/) {
            s = substr($0, RSTART+7, RLENGTH-7)
            unit = substr(s, length(s), 1)
            num  = substr(s, 1, length(s)-1) + 0
            if      (unit == "G") val = num * 1024
            else if (unit == "M") val = num
            else if (unit == "K") val = num / 1024
            else                  val = 0
            printf "%.1f", val
        }
    '
}

end=$(( $(date +%s) + DURATION ))
while [[ "$(date +%s)" -lt "$end" ]]; do
    # `ps -o ...= ...` suppresses headers; rss/vsz are in KB on macOS.
    if line=$(ps -o pcpu=,rss=,vsz= -p "$PID" 2>/dev/null); then
        # shellcheck disable=SC2086
        set -- $line
        cpu="$1"
        rss_kb="$2"
        vsz_kb="$3"
        rss_mb=$(awk -v k="$rss_kb" 'BEGIN { printf "%.1f", k/1024 }')
        vsz_mb=$(awk -v k="$vsz_kb" 'BEGIN { printf "%.1f", k/1024 }')
        printf "%s,%s,%s,%s,%s\n" \
            "$(date +%s)" "$cpu" "$rss_mb" "$vsz_mb" "$(swap_used_mb)" \
            >> "$OUT"
    else
        echo "⚠ pid $PID went away — stopping early" >&2
        break
    fi
    sleep 1
done

echo "✓ wrote $OUT"

# Inline summary
python3 - "$OUT" <<'PY'
import csv, statistics, sys
path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
if not rows:
    print("⚠ no samples captured", file=sys.stderr)
    sys.exit(0)

def stats(key):
    vals = [float(r[key]) for r in rows]
    return min(vals), statistics.mean(vals), max(vals)

print(f"\nsummary  (n={len(rows)} samples)", file=sys.stderr)
print(f"{'metric':<22} {'min':>10} {'avg':>10} {'peak':>10}", file=sys.stderr)
for k, fmt in [
    ("cpu_pct",      "{:.1f}%"),
    ("rss_mb",       "{:.0f} MB"),
    ("vsz_mb",       "{:.0f} MB"),
    ("swap_used_mb", "{:.0f} MB"),
]:
    lo, avg, hi = stats(k)
    print(f"{k:<22} {fmt.format(lo):>10} {fmt.format(avg):>10} {fmt.format(hi):>10}",
          file=sys.stderr)
PY
