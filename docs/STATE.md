# STATE

_Last updated: 2026-04-23_

## Current Focus
v0.5.3 主体功能落地完成：DebugCaptureWriter 修（partial meta + fractional seconds, commit `f8d74e0`）→ RecordingPolicy 抽取（`74529fc`）→ Hands-free 模式（`36d422d`）。等用户验证 hands-free UX，然后开 0.6B prompt echo 调研。

## Current Version
v0.5.2 (Info.plist 未 bump；等 v0.5.3 close-iteration 时一起做)

## In-flight Changes
- 9 个 hands-free 任务全部完成 (#54-#62)，79 tests pass
- 文档同步中：CHANGELOG / STATE / architecture / gotchas / roadmap / todo/v0.5.3.md
- 用户即将手动验证：tap Fn → hands-free → 1.5s 静默自停 + tap-cancel + 10s no-speech 取消

## Next Concrete Step
1. ✅ Doc 更新（这次 commit）
2. 用户手动 dogfood hands-free（数天）→ 收信号
3. Qwen 0.6B prompt echo 调研：先切 1.7B 跑几天对比 echo rate，再决定 (a)/(b)/(c)/(d) 方案
4. v0.5.3 close-iteration：bump version + devlog + tag

## Blockers / Open Questions
- 无明显 blocker
- v0.5.1 还差 `git tag v0.5.1`（task #34），可以和 v0.5.3 tag 一起补
- dogfood 数据完整率从今天起应该 ≥ 95%（writer 已修，开新 session 即可验证）
