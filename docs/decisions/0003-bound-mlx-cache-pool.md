# 0003. Bound MLX cache pool via Memory.cacheLimit

- Date: 2026-05-11
- Status: Accepted

## Context

ADR-0002 pinned ASR weights to fix cold-after-idle. Worked. But a separate
failure mode emerged: **long-uptime drift**. After ~2 days of process
uptime on the v0.7.2 build, ASR p50 walked from 340 ms (fresh 0-6h
uptime) to 831 ms (48-54h uptime) — a 2.5× degradation users described
as "卡得不行". Visible across 49 sessions / 178 segments of live
debug-capture data.

The mechanism was visible in `vmmap` against the 2-day-old PID:

- Physical footprint: **16.1 GB**
- `IOAccelerator (graphics)`: 15.6 GB resident, **13.6 GB swapped**
  (compressed), 10,425 regions
- System: 12 GB in macOS compressor pool

mlx-swift's `Memory.swift` documents the cause explicitly: "if cache
memory is unconstrained, the buffer pool policy is based on Metal's
`recommendedMaxWorkingSetSize`. Systems with more RAM will cache more
buffers." On a 24 GB Mac that's ~16 GB — the pool grows one bucket per
sequence-length shape MLX has ever seen.

v0.7.3 #B8a added per-refine `MLX.Memory.snapshot()` telemetry to
`refines.jsonl`. The data made the leak loud:

| event | cacheMemory |
|---|---|
| after 1 refine (process uptime ~1 min) | 2,359 MB |
| after 5 refines (~7 min) | 5,196 MB |
| after 7 refines (~11 h) | 5,586 MB |

~70 % of the bloat lands in the first session as MLX seeds the pool
with intermediate-buffer shapes. The rest accretes slowly as new
shape buckets appear.

Pin (ADR-0002) protects `activeMemory` — live weight pages and the
KV cache — from compressor eviction. It does NOT bound `cacheMemory`,
which is a separate region (the recycled-buffer pool). Both ASR and
refiner share the same MLX allocator. The leak was driven by refiner
inference but ASR paid the latency tax when *its* pages got compressed
during the slow drift, because the system needed RAM that the cache
pool was hoarding.

## Decision

Set `MLX.Memory.cacheLimit = 1_000_000_000` (1 GB) in `main.swift`
before `AppDelegate` constructs, so the first ASR / refiner load
runs under the cap. Excess buffers get freed back to the Metal
allocator on the next `dealloc` instead of parking in the pool.
Process-global — there is one MLX allocator pool shared across all
callers.

Also extend ADR-0002's `WiredMemoryTicket` pin pattern to the
refiner (gated by a Settings → LLM "Keep weights in memory" toggle,
2.5 GB ceiling sized for Qwen3.5-4B 4-bit ~2.0 GB weights + KV/scratch
headroom). Pin and `cacheLimit` are **orthogonal**:

| mechanism | guards | failure mode it fixes |
|---|---|---|
| `WiredMemoryTicket` pin | `activeMemory` (live weight pages) | cold-after-idle eviction |
| `Memory.cacheLimit` | `cacheMemory` (reusable buffer pool) | long-uptime drift |

Together they cover both ways the app can go slow over time.

1 GB sized to fit one refine's working-set delta (~1.3 GB observed via
#B8a snapshot delta after a single refine) plus modest reuse headroom.
Post-clamp telemetry: cacheMemory stays 986-1000 MB across 9.5 h
uptime, no spillover, no allocator churn signal in p50 latency.

## Consequences

**Positive**
- Long-uptime ASR drift eliminated. Post-fix p50 = 333 ms after 9 h+
  uptime, indistinguishable from the 0-6h cold-fresh baseline of
  340 ms on the old build.
- Process physical footprint after 9.5 h: **5.6 GB resident, 112 KB
  swapped, 2,269 IOAccelerator regions** — vs the prior 2-day-old
  process's 16.1 GB / 13.6 GB swapped / 10,425 regions.
- Compressor pressure no longer dominated by VoiceTyping. Other apps
  on the same machine regain their working sets.
- One line in `main.swift`. No allocator hooks, no per-call cache
  flushes, no shape-specific tuning.
- The #B8a telemetry that drove the decision continues to verify the
  clamp in production — `cacheMemory` is now a regression alarm, not
  a mystery.

**Negative**
- 1 GB is a guess based on n=13 post-fix dogfood. If a future refiner
  variant or longer-context ASR pushes the single-call working set
  past 1 GB, allocator churn shows up as p50 latency: buffer reuse
  cache-misses, fresh Metal alloc per call. Mitigated by #B8a's
  `peakMb` vs `cacheLimit` gap as the warning signal, but a regression
  here will *look* like "model got slower" rather than "we set the
  limit wrong".
- Locks in another mlx-swift API surface (`Memory.cacheLimit` as a
  static property). Deprecated `GPU.set(cacheLimit:)` still works as
  of 0.31.x; if mlx-swift renames the canonical property again this
  breaks at compile time. Same mitigation as ADR-0002 (pin minor
  version).
- Process-global setting — there is no per-call-site cache budget.
  Future features that want a larger reuse pool (batched inference,
  multiple model variants in flight) must coexist within this 1 GB
  or relax it globally. Accepted because the alternative was 15 GB.
- Lost the "free" cache adaptability — MLX would previously auto-scale
  up on RAM-rich Macs (40 GB+). Everyone now sits at 1 GB. Principled
  cache-tuners may want a Settings knob later if there's a workload
  where reuse beyond 1 GB is measurably valuable.
- Pin (ADR-0002) and `cacheLimit` are now **both** load-bearing for
  "VoiceTyping stays fast over uptime". Removing either breaks the
  contract — each documents the other failure mode but the coupling
  is real.

## Alternatives Considered

- **`Memory.cacheLimit = 512 MB`** — first guess before telemetry.
  #B8a snapshot delta showed single-refine working-set ~1.3 GB, so
  512 MB would force allocator churn on every refine. Rejected: a
  latency regression here would be hard to attribute back to the
  cacheLimit choice.
- **`Memory.cacheLimit = 2 MB`** — mlx-swift docs note "developers
  often find 2 MB performs just as well". True for workloads with
  fixed shapes; speech segments are variable-length. Rejected
  without dogfood; would have been retested if 1 GB showed pressure.
- **Periodic `Memory.clearCache()`** — flush the pool on idle. More
  complex (timer, trigger logic, race against in-flight inference).
  `cacheLimit` is declarative and achieves the same effect via
  dealloc-time eviction. Rejected as over-engineering.
- **Restart the app every 24 h** — a workaround, not a fix.
  VoiceTyping runs as a menu-bar background utility; expecting users
  to restart it undermines the product.
- **Drop the refiner / cloud-only LLM** — kills the on-device value
  prop for users without API keys, and doesn't fix the underlying
  ASR-side cache leak anyway (both share the MLX allocator).
- **Tune `Memory.memoryLimit` instead** — caps total MLX allocation,
  not just the recycled-buffer pool. Risk: if active + KV legitimately
  needs more than the cap during inference, the call fails outright.
  `cacheLimit` is the more conservative knob; revisit `memoryLimit`
  if we ever ship a backend whose peak active memory is unbounded.
