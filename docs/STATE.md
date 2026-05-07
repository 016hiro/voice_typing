# STATE

_Last updated: 2026-05-07_

## Current Focus

**v0.7.3 — small fixes / observability**：先修 inline refine telemetry bug（#B1），同时夹带 refine prompt（#B2）+ VAD silenceDuration（#B3）两个 cheap tuning。

## Current Version

**v0.7.3**（skeleton，主线 #B1 inline refine telemetry bug fix）

已 ship 版本：v0.7.2 (2026-05-07) / v0.7.1 (2026-05-02) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

无代码 in-flight。v0.7.2 = dogfood-driven cold-path 真正修法（#B6/B7/B8）。v0.7.1 那次 ship 的 #B3 keep-alive App Nap 修法已被 v0.7.2 整段移除——keep-alive 路线本身被证伪。

## Next Concrete Step

#B1：`LocalLiveSegmentSession.init` 加 `appendRefine` 闭包参数，runSegment 末尾调用，AppDelegate 注入侧从 captureWriter 拿。修完 ship 后 dogfood 1 周再决定 #B5（要不要 pin refiner）。

## Blockers / Open Questions

- **v0.7.3 #B5 阻塞数据** — 是否给 refiner 加 `WiredMemoryTicket` pin 待 #B4 dogfood 数据，依赖 #B1 修完 telemetry 再收 1 周
- **v0.7.2 post-ship 验证** — ASR pin 在 56 sessions / 2 天 dogfood 已确证，但样本仍偏少。如果 ship 后 1-2 周内出现新 cold-path 报告（lid close / 长闲置 / sleep-wake 异常），需要 hunt 边界条件
- v0.7.0 carry-over 仍 pending：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并
- **v0.8.0 #B5 per-app hotwords schema 决策**（推迟自 v0.7.3）—— 见 `docs/todo/v0.8.0.md`，UI 设计也未拍
- `#33` dogfood live mode 5+ 天信号采集 仍 pending
