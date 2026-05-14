# STATE

_Last updated: 2026-05-15_

## Current Focus

**v0.8.0 — Per-app hotwords + short-skip**：主线 #B5 per-app 热词配置（schema + UI 待 `/think` 拍板）+ 副线 #S1 短句 refine skip heuristic（variant C rule heuristic + Layer 1 substring hotword guard + Layer 2 phonetic hotword guard via NLTokenizer/CFStringTransform）。#S2 memoization cache 经离线 replay 验证 0% 命中率，已否决。v0.7.3 #B1 telemetry 跑出 ~50% no-op，#S1 数据驱动设计能吃掉约 15% 的 LLM wait time 而 precision 保 95.7%。

**v0.8.1 — E2E refine quality eval**（已 skeleton，未启动）：#E1 公开 ASR-correction 数据集跑 refine-only 文本 CER（CI 友好）+ #E2 自有 captures 手标 gold 跑整条 pipeline CER。不评 ASR 单独 WER/CER（Qwen 官方已提供）。

## Current Version

**v0.8.0**（skeleton，主线 #B5 per-app hotwords schema + UI 决策阻塞）

已 ship 版本：v0.7.3 (2026-05-11) / v0.7.2 (2026-05-07) / v0.7.1 (2026-05-02) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

无代码 in-flight。v0.7.3 = pin refiner toggle + MLX cacheLimit + telemetry，完整解决"用 2-3 天后转录卡顿"的 long-uptime drift；详见 `decisions/0003-bound-mlx-cache-pool.md`。

## Next Concrete Step

副线 #S1 阶段 2 进 Swift 实施 ——`RefineSkipHeuristic` 整合 variant C rule heuristic + Layer 1 substring guard（复用 `GlossaryBuilder.matchedEntryIDs`）+ Layer 2 phonetic guard（`NLTokenizer` + `CFStringTransform` + Levenshtein），挂到 `LocalLiveSegmentSession.runSegment` 入口。主线 #B5 schema 仍待 `/think` 拍板，但 #S1 已不依赖它，可独立推进。

## Blockers / Open Questions

- **v0.8.0 #B5 per-app hotwords schema 决策** —— 见 `docs/todo/v0.8.0.md`，三种 schema 候选 + UI 设计都未拍。
- **v0.7.3 post-ship 验证** —— cache clamp 1 GB 在 13 条 dogfood 上确证，但若 1-2 周内出现长 uptime 下 allocator churn（p50 拉升），调到 2 GB 再观察。
- **v0.7.0 carry-over 仍 pending**：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并。
- **v0.7.3 #B4 派生** —— refiner cold-path 分析工具（`Scripts/analysis/refine_cold_path.py` + `docs/perf/refiner-baseline.md`），进 backlog，不阻塞任何版本。
- `#33` dogfood live mode 5+ 天信号采集 仍 pending。
