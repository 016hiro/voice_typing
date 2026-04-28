# Resource baseline — VoiceTyping footprint audit

> Goal: measure current per-process memory + CPU across the realistic
> scenarios users hit (idle / per-backend loaded / during transcription /
> dual-model load), so we can decide whether candidate B (local MLX
> refiner shipped alongside ASR) is viable.
>
> All numbers below are **dev machine baseline**, not target spec. Your
> mileage will vary on smaller boxes.

## Hardware baseline

| Spec | Value |
|---|---|
| Model | MacBook Pro Mac16,8 |
| Chip | Apple M4 Pro |
| Cores | 14 (10 performance + 4 efficiency) |
| Unified RAM | **24 GB** |
| Date sampled | 2026-04-26 |
| App build | TBD (commit + version) |

## Methodology

Use `Scripts/perf/measure_footprint.sh <scenario> <duration_sec>`. It polls
`ps` once per second for the duration and dumps a CSV with:

- `cpu_pct` — % of one core (>100 means multi-core)
- `rss_mb` — resident memory (real RAM held by the process)
- `vsz_mb` — virtual address space (mmap totals; not a memory cost)
- `swap_used_mb` — system-wide swap usage (the only honest "we're paging" signal). The dev box arrived at this audit with **2297 MB swap baseline** from overnight other-app usage; we report **delta from baseline** (+0 = no new pressure caused by our scenario)

ANE / GPU utilization isn't surfaced per-process by macOS CLI, so for the
scenarios where MLX inference is running we **also screenshot Activity
Monitor → Window → GPU History (⌘4) and the Energy tab** and attach as
`docs/perf/screenshots/<scenario>.png`.

### Scenario protocol

**Pre-flight (do before every run):**
1. Quit all VoiceTyping instances (`pkill -x VoiceTyping`)
2. Quit memory-heavy apps (browsers with many tabs, Xcode if not in use)
3. Wait for swap to settle: `sysctl vm.swapusage` should show `used = 0` or single-digit MB
4. Start the dev build: `open build/VoiceTyping.app`

Each scenario below has the action you take in the app + the sampler
command I run from the terminal. Rule of thumb: start the sampler **a
second after** the action completes (so we measure the steady state, not
the load transient — that's the next scenario).

## Scenarios

### S1 — Idle (just launched)

**Setup**: launch app, wait until status bar icon is steady. Don't pick
any backend yet (or close Settings if it auto-opened).

**Sampler**: `./Scripts/perf/measure_footprint.sh s1_idle 30`

**Why**: floor — what AppKit + menubar app + Sparkle + state setup costs
before any model ever loads. Anything above this is the model's tab.

### S2 — Qwen 1.7B loaded, idle

**Setup**: from idle (S1), open Settings → Models → switch to Qwen3-ASR
1.7B. Wait until row says `Active`. Close Settings. Wait 3 seconds.

**Sampler**: `./Scripts/perf/measure_footprint.sh s2_qwen17b_idle 30`

**Why**: steady-state cost of holding the default backend in memory
between dictations.

### S3 — Qwen 1.7B during 30s transcription

**Setup**: from S2 state. **Hold Fn for 30 seconds, talk continuously**
(or count, or read), release. Sampler should run from the moment you
press Fn until ~5 seconds after the transcript pastes.

**Sampler**: `./Scripts/perf/measure_footprint.sh s3_qwen17b_record 45`
(start the sampler first, then immediately press Fn)

**Why**: peak RSS during inference (KV cache, activations) + sustained
CPU during decode.

### S4 — Qwen 0.6B loaded + 30s transcription

**Setup**: from S3 end-state. Settings → Models → switch to Qwen3-ASR
0.6B. Wait Active. Close Settings. Wait 3s. Start sampler. Hold Fn 30s.

**Sampler**: `./Scripts/perf/measure_footprint.sh s4_qwen06b_record 45`

**Why**: cheaper-backend baseline; how much do we save by going to 0.6B?

### S5 — Whisper large-v3 loaded + 30s transcription

**Setup**: from S4. Settings → Models → switch to Whisper large-v3.
Wait Active (this can take a minute on first compile). Close Settings.
Wait 3s. Start sampler. Hold Fn 30s.

**Sampler**: `./Scripts/perf/measure_footprint.sh s5_whisper_record 45`

**Why**: the non-MLX backend; useful as a cross-check against MLX path.

### S6 — Dual-MLX-model proxy (ASR + simulated local refiner)

**Setup**: from S2 state (Qwen 1.7B loaded idle). In a **separate
Terminal window**, run a 1-3B MLX LM inference job that holds its model
weights in RAM concurrently. Suggested choice (download once with
`huggingface-cli download`):

- **Light proxy**: `mlx-community/Qwen2.5-1.5B-Instruct-4bit` (~900 MB)
- **Realistic proxy**: `mlx-community/Qwen2.5-3B-Instruct-4bit` (~1.7 GB)

Run with `mlx_lm.generate --model <id> --prompt "Hello, please refine: ..." --max-tokens 200`.

While that's running its first decode, in the VoiceTyping app **hold Fn
for 30s and talk** like S3. Sampler captures the VoiceTyping process
during this concurrent load.

Also capture the second process: `pgrep -f mlx_lm.generate` then
`ps -o rss= -p <pid>` to grab its RSS once.

**Sampler**: `./Scripts/perf/measure_footprint.sh s6_dual_mlx 60`

**Why**: this is the load profile of candidate B in the worst case (ASR
finishing transcription concurrent with refiner kickoff). The two
together must fit comfortably under 16 GB to call B viable on a 16 GB
Mac, or under 24 GB to call it viable on this dev machine.

## Results

> Filled in as scenarios run. Numbers are the **peak** column from each
> sampler summary unless noted; mean shown when relevant for sustained
> CPU.

| # | Scenario | RSS peak (MB) | CPU peak (%) | CPU avg (%) | Swap used (MB) | Notes |
|---|---|---:|---:|---:|---:|---|
| S1 | idle (no backend) | n/a | n/a | n/a | n/a | skipped — app auto-loads persisted backend on launch |
| S2 | qwen17b loaded idle (cold) | **2498** | 1.3 | 0.3 | +0 | post-launch steady; weights mmap'd, no inference yet |
| S3 | qwen17b transcribe 30s | **2520** | 42.9 | 16.8 | +0 | only +22 MB delta — KV cache; ANE does the heavy lifting |
| S4 | qwen06b transcribe 30s | **914** | 42.3 | 20.8 | +0 | RSS only ~36% of 1.7B; slightly higher CPU (4-bit dequant) |
| S5 | whisper transcribe 30s | **288** | 22.0 | 15.0 | +0 | **CoreML/ANE pool not counted in RSS** — model is 2.9 GB on disk but only 288 MB process RSS |
| S6 | qwen17b + Qwen3.5-4B refiner co-resident | 80 (compressed) | 18.2 | 10.9 | +0 | sampler missed the recording window (user pressed Fn after sampler ended); macOS evicted/compressed Qwen 1.7B weights to ~80 MB while refiner held 2.6 GB. ANE non-contention measured via app log delta — see Findings |

### Refiner candidate — Qwen3.5-4B-MLX-4bit (standalone, separate process)

Helper: `Scripts/perf/hold_mlx_model.py --model mlx-community/Qwen3.5-4B-MLX-4bit`.
Two cold-start runs measured:

| Run | Load | Peak RSS | Refine inference | tok/sec | Notes |
|---|---:|---:|---:|---:|---|
| 1st (thinking on, default) | 3.66 s | 1769 MB | 3.99 s | 50.1 | output was chain-of-thought, hit max_tokens before clean output |
| 2nd (`enable_thinking=False`) | 6.48 s | 2859 MB | 0.78 s | 38.5 | clean refined output (★★★★) |
| 3rd (S6 helper, thinking off) | 3.38 s | 2605 MB | 0.90 s | 33.3 | `ru_maxrss` peak; current RSS via `ps` was ~540 MB after stable load |

**Refine sample** (`SAMPLE_ASR_OUTPUT` in `hold_mlx_model.py`):

> **Input** (raw ASR, zh-EN with fillers, no punctuation):
> `嗯 那个 我们今天 主要要做的事情就是 把这个 voice typing 的 perf baseline 这个事情收完 然后看一下 candidate B 那个本地 refiner 能不能上 嗯就这样`
>
> **Output (Qwen3.5-4B, thinking disabled)**:
> `今天我们主要要做的事情就是把 voice typing 的 perf baseline 收完，然后看一下 candidate B 那个本地 refiner 能不能上。就这样。`
>
> Quality ★★★★ — fillers (`嗯`/`那个`) removed, English terms preserved, comma + period inserted at natural breakpoints. Meaning unchanged.

### Refiner candidate — Gemma 4 E4B (NOT MEASURED)

`lmstudio-community/gemma-4-E4B-it-MLX-4bit` (downloaded, 2.7 GB on disk) **could not be loaded** with current tooling:
- mlx-lm errors: 126 extra params (`language_model.model.layers.X.self_attn.k_proj/v_proj` missing in mlx-lm's Gemma model definition)
- mlx-vlm 0.4.4 (latest as of audit): 2 extra params (`per_layer_model_projection.biases/scales`) — Matformer compression layer not yet supported

Comparison deferred. If a future audit needs Gemma family for comparison, switch to `mlx-community/gemma-3-4b-it-4bit` (text-only, mature mlx-lm support).

### ASR latency under co-resident refiner (ANE contention check)

From VoiceTyping app log (`subsystem == "com.voicetyping.app"`, `backend=qwen-asr-1.7b`, `mode=live`):

| Time | Scenario | tail asr_ms | Notes |
|---|---|---:|---|
| 00:25:42 | "warm" Fn press, no refiner loaded yet | **550** | first segment after weights paged out — page-in cost dominates |
| 00:35:24 | refiner held 2.6 GB; user records | **99** | tail segment after warm decoding loop; faster than the cold case |

**ANE contention not observed** at our scale. Refiner inference is sequential to ASR (refiner kicks off only after Fn release / ASR completion), so they do not actually compete on ANE simultaneously. Even when both processes' weights are coresident in unified memory, ASR tail latency stays sub-100ms.

## Findings

### 1. MLX backends carry RSS; CoreML doesn't

The single biggest insight from this audit: **MLX uses unified memory directly, so weights count toward process RSS. CoreML offloads to ANE, where weights live in a dedicated kernel pool that does NOT show up in `ps`-reported RSS.**

| Backend | On-disk size | Process RSS during transcribe |
|---|---:|---:|
| Qwen3-ASR 1.7B (MLX 8-bit) | ~1.7 GB | **2520 MB** |
| Qwen3-ASR 0.6B (MLX 4-bit) | ~600 MB | **914 MB** |
| Whisper large-v3 (CoreML) | **2.9 GB** | **288 MB** |

For users on tight RAM (8–16 GB), Whisper is **dramatically more memory-friendly** than Qwen, despite being almost 2× larger on disk. The cost to switch is one-time CoreML→ANE compile (3+ minutes on M4 Pro for large-v3, cached system-wide thereafter).

### 2. Inference adds negligible RSS over idle (KV cache only)

S2 idle (Qwen 1.7B) = 2498 MB. S3 during 30s transcribe = 2520 MB peak. **Delta = +22 MB.** Weights are mmap'd at recognizer init; inference allocates only KV cache + activations. Going from "idle" to "actively transcribing" is essentially free in memory terms.

### 3. macOS aggressively compresses idle MLX weights under pressure

S6 demonstrated this clearly: with Qwen3.5-4B holding ~2.6 GB and VoiceTyping idle, VoiceTyping's RSS dropped from 2498 MB to **80 MB**. Pages went to the compressor segment; no swap-out (the dev box's 1824 MB swap was overnight residue from other apps, unchanged during S6).

**Implication for user-perceived latency**: switching from "idle for minutes" back to "press Fn" will have a one-time fault-back cost as compressed pages decompress. Our log shows this is in the few-hundred-ms range (550ms cold tail vs 99ms warm). Acceptable.

### 4. ANE contention is a non-issue for our usage pattern

Refiner runs sequentially after ASR completes (Fn-release triggers refiner kickoff). They do not share the ANE simultaneously. Even with refiner weights coresident, ASR latency was unaffected (in fact slightly faster due to recent activity).

### 5. CPU is bottleneck-free on M4 Pro

Peak CPU during transcription stayed under **45% of one core** (~3% total on 14-core M4 Pro). The heavy lifting goes to ANE. CPU is not a constraint for any backend.

## Headroom on 24 GB (this dev box)

OS + Finder + typical user apps (browser, IDE, IM): **~5 GB baseline**.

| Resident config | Process RSS sum | Headroom (24 GB - baseline - sum) |
|---|---:|---:|
| Qwen 1.7B ASR alone | 2.5 GB | ~16.5 GB |
| + Qwen3.5-4B refiner | ~5.1 GB | **~13.9 GB** |
| + Whisper CoreML (in addition) | +0.3 GB | ~13.6 GB |

Plenty of room on 24 GB. Verdict for this machine class: **comfortable**.

## Per-RAM-tier extrapolation (informed estimates)

Assumes typical user load: macOS + browser + IDE + chat = ~3–5 GB baseline.

| RAM | OS+user baseline | Headroom | Qwen 1.7B alone (2.5 GB) | + 4B refiner (5.1 GB) | + 2B refiner (~3.5 GB est) |
|---|---:|---:|---|---|---|
| **8 GB** | ~3 GB | ~5 GB | ⚠ tight, swap likely | ❌ infeasible | ❌ infeasible |
| **16 GB** | ~4 GB | ~12 GB | ✓ comfortable | ⚠ tight under multitasking | ✓ workable |
| **24 GB+** | ~5 GB | ~19 GB | ✓✓ | ✓ | ✓ |

## Decision — local refiner = `mlx-community/Qwen3.5-4B-MLX-4bit`

**Locked 2026-04-29.** Rationale:

1. **Same family as ASR (Qwen)** — coherent prompt style + training data, consistent zh/en handling
2. **3.66–6.48 s cold load, ~0.9 s refine for ~30-token output** — fits the "release Fn → see refined text" UX budget (target < 2 s end-to-end)
3. **Quality ★★★★ on representative zh-EN ASR refine task** — fillers removed, terms preserved, punctuation correct
4. **2.6 GB process RSS** — fits comfortably on 24 GB, marginal on 16 GB, infeasible on 8 GB → tier behavior below
5. **`enable_thinking=False` required** — Qwen3 series defaults to chain-of-thought; we suppress for direct refine output

### Tiered ship strategy

Detect RAM at launch via `sysctl -n hw.memsize` and branch:

| Tier | Default ASR | Local refiner | Cloud refiner |
|---|---|---|---|
| **8 GB** | Whisper large-v3 (CoreML, ~0.3 GB RSS) **or** Qwen 0.6B | hidden / not offered | available, recommended |
| **16 GB** | Qwen 1.7B (current default) | Qwen3.5-4B exposed but **OFF by default**, with ⚠ "may swap on heavy multitasking" copy | available |
| **24 GB+** | Qwen 1.7B | Qwen3.5-4B exposed, **OFF by default** initially (avoid surprise behavior change for upgraders); user opts in | available |

For all tiers: existing cloud refiner path stays unchanged. Local refiner is **additive, opt-in**.

### Known quirks for implementation

- **macOS will compress refiner weights when idle** — first refine after a long pause has ~500 ms page-in cost (similar to ASR cold-touch). Pre-warm on Fn↑ might help.
- **Use Qwen chat template with `enable_thinking=False`** — without it, the model dumps reasoning tokens before the refined output and runs over `max_tokens`.
- **mlx-swift integration path** — existing app uses `swift-mlx` via `soniqo/speech-swift` for Qwen ASR. Refiner can use the same MLX runtime; no new framework dependency.
- **First-load 6.5 s cost** — needs to be lazy / background-warmed, not blocking on Fn↑.

## Open questions / not measured

- Whether Qwen 1.7B unloads when user swaps to Whisper, or both stay resident (S5 was done after a fresh launch, so we couldn't observe the transition)
- ANE % utilization quantification (Activity Monitor only, no CLI)
- 16 GB Mac real numbers — the tier-2 row is extrapolation; needs validation on a 16 GB box during dogfood
- Memory pressure index over time (we sampled `vm.swapusage` total but not the kernel's "memory pressure" heuristic; useful for the live "is candidate B causing pain?" telemetry signal)
- Refine quality on a wider input distribution (we tested one representative zh-EN string; full validation needs a corpus of real ASR outputs from `debug-captures/`)

