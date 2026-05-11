# STATE

_Last updated: 2026-05-11_

## Current Focus

**v0.8.0 — Per-app hotwords**：主线 #B5 per-app 热词配置（schema + UI 待 `/think` 拍板）+ 副线 #S1 短句 refine skip heuristic（v0.7.3 #B1 telemetry 跑出 40% no-op，数据驱动优化短句 p50）。

## Current Version

**v0.8.0**（skeleton，主线 #B5 per-app hotwords schema + UI 决策阻塞）

已 ship 版本：v0.7.3 (2026-05-11) / v0.7.2 (2026-05-07) / v0.7.1 (2026-05-02) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

无代码 in-flight。v0.7.3 = pin refiner toggle + MLX cacheLimit + telemetry，完整解决"用 2-3 天后转录卡顿"的 long-uptime drift；详见 `decisions/0003-bound-mlx-cache-pool.md`。

## Next Concrete Step

`/think` 拍板 v0.8.0 #B5 schema（a/b/c：ContextProfile.dictionaryFilter 子集 / 独立 PerAppDictionaryStore / dictionaryMode enum）+ profile editor 多选 UI 设计。在此之前可以先做副线 #S1 短句 skip heuristic 的离线 replay 工具——`refines.jsonl` 已有 139+ 条带 `mlxCacheMb` 字段的数据可以跑 confusion matrix。

## Blockers / Open Questions

- **v0.8.0 #B5 per-app hotwords schema 决策** —— 见 `docs/todo/v0.8.0.md`，三种 schema 候选 + UI 设计都未拍。
- **v0.7.3 post-ship 验证** —— cache clamp 1 GB 在 13 条 dogfood 上确证，但若 1-2 周内出现长 uptime 下 allocator churn（p50 拉升），调到 2 GB 再观察。
- **v0.7.0 carry-over 仍 pending**：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并。
- **v0.7.3 #B4 派生** —— refiner cold-path 分析工具（`Scripts/analysis/refine_cold_path.py` + `docs/perf/refiner-baseline.md`），进 backlog，不阻塞任何版本。
- `#33` dogfood live mode 5+ 天信号采集 仍 pending。
