# STATE

_Last updated: 2026-04-23_

## Current Focus
v0.5.3 主体功能全部 ship：DebugCaptureWriter 修（`f8d74e0`）→ RecordingPolicy 抽取（`74529fc`）→ Hands-free 模式（`36d422d`）→ 文档同步（`8e2d6de`）→ 胶囊色统一（`ad066d1`）。等用户 dogfood 验证 → close-iteration。原定第三块 Qwen 0.6B echo 调研移到 backlog.md 数据驱动调研段，不卡版本节奏。

## Current Version
v0.5.2 (Info.plist 未 bump；等 v0.5.3 close-iteration 时一起做)

## In-flight Changes
- 9 个 hands-free 任务全部完成 (#54-#62)，79 tests pass
- 文档同步中：CHANGELOG / STATE / architecture / gotchas / roadmap / todo/v0.5.3.md
- 用户即将手动验证：tap Fn → hands-free → 1.5s 静默自停 + tap-cancel + 10s no-speech 取消

## Next Concrete Step
1. ✅ Doc 更新 + 胶囊色统一
2. 用户手动 dogfood hands-free（数天）→ 收信号（阈值校准进 backlog 数据驱动调研段）
3. v0.5.3 close-iteration：bump version + devlog + tag

## Blockers / Open Questions
- 无明显 blocker
- v0.5.1 还差 `git tag v0.5.1`（task #34），可以和 v0.5.3 tag 一起补
- dogfood 数据完整率从今天起应该 ≥ 95%（writer 已修，开新 session 即可验证）
