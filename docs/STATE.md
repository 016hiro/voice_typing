# STATE

_Last updated: 2026-04-29_

## Current Focus

**两条并行分支 in-flight (2026-04-29)**：

1. **`v0.6.4` (branch `v0.6.4`)** — ASR keep-alive (anti-compressor) patch。Dogfood 暴露存量 bug：1.7B MLX 权重闲置 1-2h 后被 macOS compressor 压缩，下次 Fn 要等 9-30s 解压（baseline 99-550ms 的 17-56×）。修法：90s timer 跑 200ms 静音 dummy transcribe 防压缩。Scope: [`docs/todo/v0.6.4.md`](todo/v0.6.4.md)。预计 2-3 天。**用户委托另一 agent 实施**。

2. **`main` (待 branch v0.6.3)** — 本地 MLX refiner (Qwen3.5-4B-MLX-4bit)。Scope locked 2026-04-29，#R1 + #R4 done，#R2-R10 待开工。Tier strategy: 8 GB 不暴露 / 16 GB opt-in 带警告 / 24 GB+ opt-in 默认 OFF。Scope: [`docs/todo/v0.6.3.md`](todo/v0.6.3.md)。

两条互不冲突（v0.6.4 只动 ASR 侧，v0.6.3 只动 LLM 侧）。Ship 顺序无依赖。

## Current Version

v0.6.1（已 ship） — 当前 dogfood 中。

下一版号分配：
- **v0.6.2** burn 在回滚的 hotkey picker 上 (2026-04-26 reverted)
- **v0.6.3** = 本地 MLX refiner（待开工）
- **v0.6.4** = ASR 防压缩 keep-alive patch（待开工，独立分支）

## In-flight Changes

代码 in-flight:
- 无（两条分支都是 scope 锁定，待开工状态）

已完成的非代码工作:
- 资源占用基线 audit (S2-S6) + 2 个新 Findings (compressor 严重性 + Swift spike 验证) → [`docs/perf/baseline.md`](perf/baseline.md)
- Helper script: [`Scripts/perf/measure_footprint.sh`](../Scripts/perf/measure_footprint.sh) + [`Scripts/perf/hold_mlx_model.py`](../Scripts/perf/hold_mlx_model.py)
- v0.6.3 scope doc: [`docs/todo/v0.6.3.md`](todo/v0.6.3.md) — 5 新增 + 9 修改文件 + R1-R10 (R1+R4 done)
- v0.6.4 scope doc: [`docs/todo/v0.6.4.md`](todo/v0.6.4.md) — 2 新增 + 2-3 修改 + K1-K7 (K1 done)
- **v0.6.3 #R4 spike artifact**：[`Scripts/perf/refiner_spike/`](../Scripts/perf/refiner_spike/) — throwaway SwiftPM project 验证 mlx-swift-lm 集成路径。**保留作为 #R6 实施参考**，不要删

## Next Concrete Step

**v0.6.4 分支** (其他 agent 接手): 开 #K2 `Sources/VoiceTyping/ASR/ASRKeepAlive.swift` + 单测。设计参考 v0.6.4.md §1 伪代码。

**v0.6.3 分支** (待开): 开 #R2 LLMRefining 协议抽取 (纯 refactor 零行为变化)。spike 已验 #R4，剩下都是实施。#R6 warm-up 策略已修订：refiner **不**做 keep-alive，接受 cold-decompress + UI "warming up..."，与 v0.6.4 ASR 必须 warm 的策略相反（用户决策）。

## Blockers / Open Questions

- 16 GB Mac 真实数据待 dogfood 验证（baseline.md 是从 24 GB 外推的）
- v0.6.4 90s cadence 是否合适，需要 dogfood 一周后看 `tail asr_ms` 分布
- v0.6.1 dogfood 攒数据：100 KB/s 阈值 + 5x 倍率定稿、hf-mirror 命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
