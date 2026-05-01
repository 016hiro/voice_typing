# STATE

_Last updated: 2026-05-01_

## Current Focus

**v0.6.3 + v0.6.4 双发完毕（2026-05-01），下一步 v0.7.0 流式 refine UX。**

- **v0.6.3** (本地 MLX refiner) 由 main 推进，ship 在前
- **v0.6.4** (ASR keep-alive 防 compressor) 由另一个 agent 在 worktree 并行做完，rebase 到 main 后 ship。两个版本零代码冲突——v0.6.3 改 LLM 侧，v0.6.4 改 ASR 侧

## Current Version

**v0.7.0**（开发中，待 scope 详化 + 开工）。已 ship 版本：v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

下一版主线：
- v0.7.0 = 流式 refine UX + R9 Cmd+Z chain（main 主线下一版）

## In-flight Changes

代码 in-flight:
- 无（v0.6.3 + v0.6.4 都 ship，worktree 已 prune，v0.7.0 待开工）

已完成的非代码工作:
- v0.6.3 close-iteration（devlog / CHANGELOG / 归档 todo / 创建 v0.7.0 skeleton）
- v0.6.4 close（agent 留下未 commit 的 K2+K3+K7，已 rebase + commit + merge + tag + DMG + appcast）
- v0.7.0 scope skeleton: [`docs/todo/v0.7.0.md`](todo/v0.7.0.md) — S1-S9 待开工
- 16 GB Mac dogfood 任务迁入 [`docs/todo/backlog.md`](todo/backlog.md)
- v0.6.4 worktree (`/Users/lijunjie/github/voice_typing-v0.6.4`) 已 `git worktree remove`

## Next Concrete Step

**v0.7.0 主线**：#R1-#R9 全部 code-complete (commits a9c88bc..2336e35)。`make test` 208 pass / 0 fail；release build 干净。剩 #R10 (integration test 套) + #R11 (16 GB Mac dogfood) + 收尾 (Info.plist bump / devlog / CHANGELOG / DMG / appcast)。

**用户验收清单待跑** —— Settings UI 三段 picker 视觉、capsule 流式 "Refining (N chars)"、Esc 取消、focus-loss 自动停、Notion auto-batch、Live mode 段终 refine + 多步 Cmd+Z replace。详见 chat 中给的 checklist。

## Blockers / Open Questions

- v0.7.0 流式 paste 方案选型——三个候选都有兼容性坑，需 spike 实测
- v0.7.0 R9 Cmd+Z 调研：跨 app NSUndoManager 不可控，可能需要退化方案
- 16 GB Mac 真实数据待 dogfood（baseline.md 是从 24 GB 外推的）
- **v0.6.4 K4 manual 验证**：跑 `vmmap $(pgrep VoiceTyping)` 看 MLX region 长期保持 active；dogfood 一周后看 `tail asr_ms` 分布有无 9s+ outlier
- v0.6.3 dogfood 攒数据：本地 refiner cold-decompress 真实分布、`refines.jsonl` cloud vs local 质量比对、Settings UI 700pt 在 13" Mac 屏幕上的视觉感受
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
