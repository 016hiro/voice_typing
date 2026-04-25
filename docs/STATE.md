# STATE

_Last updated: 2026-04-26_

## Current Focus

v0.6.1 已 ship（DMG + Sparkle appcast 全链路 live）。**v0.6.2 已 dropped 2026-04-26**——hotkey picker 实现完成自测后用户判定"感觉好像没什么用"，整版 revert（commit `ede4bf3`）。理由：主流语音输入（Wispr Flow / macOS Dictation 等）都是 Fn-only，无市场证据。Fn 保持唯一 PTT 键。Scope 历史保留在 [`docs/todo/v0.6.2.md`](todo/v0.6.2.md)。**下一版号 + 主题 TBD**——沿用 dogfood 模式，不预 bump。

## Current Version

v0.6.1（已 ship） — 当前 dogfood 中，无 in-flight 开发

## In-flight Changes

无。v0.6.2 hotkey picker 已 dropped + revert。

## Next Concrete Step

继续 dogfood v0.6.1（HF mirror 命中率 + 100 KB/s 阈值 + 5x 倍率验证）；下一版主题 TBD，等用户/dogfood 暴露真实信号再定。

## Blockers / Open Questions

- v0.6.1 dogfood 攒数据：100 KB/s 阈值 + 5x 倍率定稿、hf-mirror 命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
- 下一版主题 TBD（不再预设 hotkey picker）
