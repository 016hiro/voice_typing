# STATE

_Last updated: 2026-05-21_

## Current Focus

**v0.8.1 — E2E refine quality eval**（skeleton 2026-05-12，待启动）：#E1 公开 ASR-correction 数据集跑 refine-only 文本 CER（CI 友好）+ #E2 自有 captures 手标 gold 跑整条 pipeline CER。不评 ASR 单独 WER/CER（Qwen 官方已提供）。两套 eval 在 v0.8.0 prompt 改后特别有价值——能 catch 未来 cleanup-mode 行为漂移。

## Current Version

**v0.8.1**（待启动）。

已 ship 版本：v0.8.0 (2026-05-21) / v0.7.3 (2026-05-11) / v0.7.2 (2026-05-07) / v0.7.1 (2026-05-02) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

无（v0.8.0 已 close-iteration + dogfood 验证，待 `make release + gh release`）。v0.8.0 关键决策 `decisions/0005-per-app-independent-hotwords.md`（supersedes 0004）：`ContextProfile` 砍 `systemPromptSnippet`，换成 `entries: [DictionaryEntry]` + `includeGlobal: Bool`——全局共享 baseline + app 私有追加。Settings 页 "Profiles" → "App hotwords"。

## Next Concrete Step

`make release + gh release` 触发 v0.8.0 发版，然后启动 v0.8.1 #E1（refine-only CER eval）——先扫公开 ASR-correction 数据集挑 1-2 个许可证 OK 的，写 `Scripts/eval/refine_cer.py` 跑出基线。v0.8.0 prompt 修复（`MUST NOT rewrite` vs glossary `Rewrite` 内部矛盾）的稳定性验证用 #E1 兜底。

## Blockers / Open Questions

- **v0.8.0 post-ship 验证** —— 旧 profile JSON 静默丢 snippet/dictionaryFilter 字段并重置为"用全局+无私有"，无报告 = pass；refine cleanup mode 行为稳定性靠 #E1 兜底。
- **#S1 dogfood ≥1 周后跑 `skip_gate_report.py`** —— 已迁 backlog，1 周后回看 phonetic guard FP 率，必要时收紧阈值。
- **v0.7.3 post-ship 验证** —— cache clamp 1 GB 在 13 条 dogfood 上确证，但若 1-2 周内出现长 uptime 下 allocator churn（p50 拉升），调到 2 GB 再观察。
- **v0.7.0 carry-over 仍 pending**：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并。
- **v0.7.3 #B4 派生** —— refiner cold-path 分析工具（`Scripts/analysis/refine_cold_path.py` + `docs/perf/refiner-baseline.md`），进 backlog，不阻塞任何版本。
- `#33` dogfood live mode 5+ 天信号采集 仍 pending。
