# STATE

_Last updated: 2026-05-07_

## Current Focus

**v0.7.2 — main 线 #B5 per-app hotwords 待 `/think` 拍 schema**

## Current Version

**v0.7.2**（skeleton，主线 #B5 per-app hotwords 待 `/think` 拍板）

已 ship 版本：v0.7.1 (2026-05-07) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

无代码 in-flight。v0.7.1 已 ship（37bcd4b #B7 pin / b979e92 #B8 teardown / ecc10dc ADR-0002 docs 三连 commit）。

## Next Concrete Step

`/think` 拍板 #B5 schema (a/b/c)：`ContextProfile.dictionaryFilter: [UUID]?` 引用全局子集 vs 完全独立 `PerAppDictionaryStore` vs `dictionaryMode` enum。

## Blockers / Open Questions

- **#B5 schema 决策** — 见上，UI 设计也未拍
- v0.7.0 carry-over 仍 pending：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并
- v0.6.3 dogfood 攒数据：`refines.jsonl` cloud vs local 质量比对（`refine_quality.py` 已就位）
- `#33` dogfood live mode 5+ 天信号采集 仍 pending
