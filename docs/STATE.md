# STATE

_Last updated: 2026-05-01_

## Current Focus

**v0.6.3 ship 完毕（2026-05-01），下一步 v0.7.0 流式 refine UX。**

并行：

1. **`v0.6.4` (branch `v0.6.4`)** — ASR keep-alive (anti-compressor)。**用户委托另一 agent 实施**，独立分支与 v0.6.3 / main 不冲突。Scope: [`docs/todo/v0.6.4.md`](todo/v0.6.4.md)
2. **main (待 branch v0.7.0)** — 流式 refine UX + Live × Refine Cmd+Z chain（v0.6.3 R9 punt 过来 + 新加 R11 streaming）。Scope skeleton: [`docs/todo/v0.7.0.md`](todo/v0.7.0.md)，待详化 + ADR

## Current Version

**v0.7.0**（开发中，待 scope 详化 + 开工）。已 ship 版本：v0.6.3 (2026-05-01)。

下一版号分配：
- v0.6.4 = ASR 防压缩 keep-alive patch（独立分支，由另一 agent 推进）
- v0.7.0 = 流式 refine UX + Cmd+Z chain（main 主线下一版）

## In-flight Changes

代码 in-flight:
- 无（v0.6.3 已 ship，v0.7.0 待开工）

已完成的非代码工作:
- v0.6.3 close-iteration（devlog / CHANGELOG / 归档 todo / 创建 v0.7.0 skeleton）
- v0.7.0 scope skeleton: [`docs/todo/v0.7.0.md`](todo/v0.7.0.md) — S1-S9 待开工
- 16 GB Mac dogfood 任务迁入 [`docs/todo/backlog.md`](todo/backlog.md)

## Next Concrete Step

**v0.7.0 主线**：开 #S1，详化 scope 并写 ADR 锁定决策（流式 inject 方案 / API shape / raw-first 互斥 / Cmd+Z 调研结论）。先 spike #S3 三个 inject 方案（Cmd+V / CGEvent / NSAccessibility），定方案后再展开 #S2 协议改造。

**v0.6.4 分支** (其他 agent)：继续 #K2-K7 进度。

## Blockers / Open Questions

- v0.7.0 流式 paste 方案选型——三个候选都有兼容性坑，需 spike 实测
- v0.7.0 R9 Cmd+Z 调研：跨 app NSUndoManager 不可控，可能需要退化方案
- 16 GB Mac 真实数据待 dogfood（baseline.md 是从 24 GB 外推的）
- v0.6.4 90s cadence 是否合适，需要 dogfood 一周后看 `tail asr_ms` 分布
- v0.6.3 dogfood 攒数据：本地 refiner cold-decompress 真实分布、`refines.jsonl` cloud vs local 质量比对、Settings UI 700pt 在 13" Mac 屏幕上的视觉感受
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
