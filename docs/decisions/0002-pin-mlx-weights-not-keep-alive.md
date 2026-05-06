# 0002. Pin MLX weights via WiredMemoryTicket, not periodic dummy inference

- Date: 2026-05-07
- Status: Accepted

## Context

After ~1-2 hours of app idle, the first transcribe-after-idle landed at
30-50 s instead of the warm baseline of 100-700 ms. The hung threads' stacks
all sat inside `eval_impl → condition_variable::wait` on cold MLX paths.
Process RSS had collapsed from ~5 GB to ~60 MB, indicating the macOS
unified-memory compressor had evicted the MLX weight pages while idle.

v0.6.4 shipped `ASRKeepAlive`: a 90 s `Timer` that ran a 200 ms
silent-buffer dummy `transcribe()` to "keep weights warm". Three follow-up
fixes (App Nap suppression, `NSWorkspace.didWakeNotification`, off-`.background`
QoS) tried to make it reliable. None worked: dogfood across v0.6.4..v0.7.1
still showed a worse `≥5 s` rate (5.3 %) than v0.6.1 (2.2 %) — every
"warm-up" tick was *itself* cold-path, sometimes running 30-45 s on silent
input because the decoder lacked an EOS signal. The keep-alive timer was
tackling a symptom (cold pages → slow inference) instead of the cause
(compressor eviction).

The MLX community had already converged on the canonical fix:
`mlx_set_wired_limit` (Metal residency-set sizing). mlx-swift exposes it
via the `WiredMemoryManager` actor and `WiredMemoryTicket` value type.
A throwaway #B7 spike pinning 1.5 GB across 56 sessions / 84 segments of
2-day dogfood produced:

| metric | pre-#B7 | post-#B7 |
|---|---|---|
| `≥5 s` rate | 5.3 % | 0.00 % |
| `transcribeMs` max | 30-51 s | 3.56 s |
| `TranscribeWatchdog` firings | 18 / 50 min idle | 0 |
| first-segment after 11.5 h overnight idle | 37-51 s | 1.08 s |

## Decision

Use mlx-swift's `WiredMemoryTicket(.active)` to pin MLX weight pages
against the macOS unified-memory compressor. Start the ticket once after
`Qwen3ASRModel.fromPretrained`, never call `end()` until the recognizer
unloads. Do **not** add background timer-driven warm-up loops, periodic
dummy inferences, or work-gates designed to coexist with such timers.

For ASR specifically: 1.5 GB ceiling on `QwenASRRecognizer` covers Qwen3-ASR
1.7B 4-bit (~850 MB weights + Metal scratch headroom) with margin under
`GPU.maxRecommendedWorkingSetBytes()` on every supported Mac.

`.active` is the correct kind, not `.reservation`: per
mlx-swift's `Articles/wired-memory.md`, `.reservation` participates in
admission and limit *computation* but explicitly does NOT keep the wired
limit elevated while idle — which is exactly the window we need to protect.

## Consequences

**Positive**
- Cold-path tail completely eliminated: max segment latency 3.56 s, p99
  3.56 s, with 11+ hours of idle preceding.
- ~250 lines of code removed (`ASRKeepAlive.swift`, `MLXWorkGate.swift`,
  `ASRKeepAliveTests.swift`, lifecycle wiring, gate wraps in 4 sites).
- No more 90-s dummy transcribes burning battery while idle.
- No more lock contention between background ticks and user MLX work
  (Metal command queue, `CompiledFunction` `NSRecursiveLock`).
- Behavior is now declarative ("keep these weights resident") instead of
  imperative ("wake them up periodically and hope they stay warm").

**Negative**
- 1.5 GB of unified memory is reserved while the ASR model is loaded,
  even when the user is idle. On 8 GB Macs this is ~19 % of physical RAM
  unavailable to other apps' compressor relief. Anyone debugging
  memory-pressure complaints in the future has to know about this knob.
- Process-wide global: only one wired limit exists per process. If a
  future feature wants to pin Whisper or refiner weights too, all callers
  must coordinate through `WiredMemoryManager` (which they already do —
  but the contract is now load-bearing).
- Locks us further into mlx-swift's internal API surface. If
  `WiredMemoryTicket` is ever renamed/removed across mlx-swift versions,
  this breaks at compile time. Mitigated by pinning to
  `.upToNextMinor(from: "0.31.3")`.
- Backend swap (Qwen → Whisper or different Qwen variant) drops the limit
  to 0 via `unload()` and the next backend has to re-establish its own
  ticket. Cheap, but a contract every future backend must honor if it's
  MLX-backed.
- `TranscribeWatchdog` (the passive observer) becomes the *only* signal
  for MLX-side hangs. If a non-compressor failure mode emerges later, we
  may take longer to spot it without the keep-alive's tick-counter
  telemetry as a sanity check.

## Alternatives Considered

- **Keep `ASRKeepAlive`, fix the bugs in it** — what v0.7.1 #B3/#B6 did.
  Failed: ticks themselves run cold-path on silent input, so the timer
  is racing against the compressor eviction window with the same
  cold-decompress cost the user would pay anyway. Plus measurable battery
  cost from 90 s wake-ups.
- **`WiredMemoryTicket(.reservation)`** — nominally the right semantic
  fit ("we plan to use this much"), but mlx-swift docs are explicit:
  reservations don't keep the wired limit elevated while idle. Wrong tool
  for this exact problem.
- **Lock the model to ANE / drop MLX entirely** — Whisper backends already
  do this and are immune. Would mean dropping Qwen3-ASR's quality
  advantage on Chinese, the explicit user-visible reason we ship Qwen.
- **Tell users to "keep the app foregrounded"** — non-starter; voice typing
  is a background-utility menu-bar app by design.
- **Touch a small slice of weight memory periodically (no full inference)** —
  would need to bypass MLX's allocator to know which pages to touch. Both
  invasive and fragile against MLX upgrades; pin via the supported API
  achieves the same effect with one line.
