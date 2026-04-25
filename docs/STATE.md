# STATE

_Last updated: 2026-04-26_

## Current Focus

v0.6.1 已 ship（DMG + Sparkle appcast 全链路 live）。下一版 **v0.6.2 主题：Push-to-talk 键可配置**——Fn 扩到 5 个 curated 候选（Fn / Right Option / Right Command / F13 / F14）。Settings 加 Hotkey tab + 实时按键检测指示灯 + Reset 按钮。底层 `FnHotkeyMonitor` 一般化为 `HotkeyMonitor`，事件流签名不变。Scope 见 [`docs/todo/v0.6.2.md`](todo/v0.6.2.md)。

## Current Version

v0.6.1（已 ship）→ 开发中：v0.6.2

## In-flight Changes

v0.6.2 (#80-#88)：

- HotkeyTrigger enum：5 个 curated 候选 + keycode 映射 + 副作用文案
- HotkeyMonitor（rename FnHotkeyMonitor）：trigger 通用化 + swap API（synthesized release on swap）
- AppState：`pushToTalkTrigger` 字段 + UserDefaults
- Settings 新 HotkeyTab：radio + Test 指示灯 + Reset 按钮
- AppDelegate：监听 trigger 变化 → swap monitor

未开工，scope locked 2026-04-26。落地序见 todo doc。

## Next Concrete Step

执行 #81 spike：dev 机上验证 Right Option / Right Command 的 keycode 区分（61 vs 58 / 54 vs 55）。如果不可靠，降级为 "Any Option / Any Command"。这一步决定 HotkeyTrigger enum 的最终分辨粒度。

## Blockers / Open Questions

- Right modifier keycode 区分可靠性（待 #81 spike 验证）
- F13/F14 在常规笔记本无、外接键盘各家映射不同 → Test 指示灯是 UX guard
- v0.6.1 dogfood 攒数据：100 KB/s 阈值 + 5x 倍率定稿、hf-mirror 命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
