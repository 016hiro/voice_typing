# STATE

_Last updated: 2026-04-29_

## Current Focus

v0.6.1 已 ship。v0.6.2 hotkey picker dropped (2026-04-26)。**下一版主题已锁：本地 MLX refiner (candidate B)** — 选型 `mlx-community/Qwen3.5-4B-MLX-4bit`，决策依据见 [`docs/perf/baseline.md`](perf/baseline.md)。Tier strategy: 8 GB 不暴露 / 16 GB opt-in 带警告 / 24 GB+ opt-in 默认 OFF。版本号未定（暂记 v0.6.x），实施前先开 scope doc。

## Current Version

v0.6.1（已 ship） — 当前 dogfood 中，无 in-flight 开发

## In-flight Changes

无代码 in-flight。已完成的非代码工作：
- 资源占用基线 audit (S2-S6) — 数据 + tier 推荐 + Qwen3.5-4B 选型 → [`docs/perf/baseline.md`](perf/baseline.md)
- Helper script: [`Scripts/perf/measure_footprint.sh`](../Scripts/perf/measure_footprint.sh) + [`Scripts/perf/hold_mlx_model.py`](../Scripts/perf/hold_mlx_model.py)

## Next Concrete Step

写 candidate B scope doc (`docs/todo/v0.6.x.md` 或下一版号)：协议抽象 (LLMRefiner → 多实现) + LocalMLXRefiner Swift 实现 (mlx-swift) + Tier-aware Settings UI + Qwen3.5-4B bundle/download + lazy-load + warm-up 策略。文件改动估 ~8-10 个，scope doc 锁后再开工。

## Blockers / Open Questions

- mlx-swift LLM 集成成本未估（仓库已有 swift-mlx via speech-swift，但 LLM 推理是新路径）
- 16 GB Mac 真实数据待 dogfood 验证（baseline.md 是从 24 GB 外推的）
- v0.6.1 dogfood 攒数据：100 KB/s 阈值 + 5x 倍率定稿、hf-mirror 命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
