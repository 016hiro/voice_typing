# STATE

_Last updated: 2026-04-26_

## Current Focus

v0.6.2 实现完成（#80-#88 全部落地，104 tests pass，build 绿）。功能完整：HotkeyTrigger enum + HotkeyMonitor 通用化 + swap API + AppState.pushToTalkTrigger 持久化 + Settings 新 Hotkey tab + Reset 按钮 + Test 指示灯 + README/CHANGELOG。**下一步**：自测 UI（4 个非 Fn 选项 + Reset 行为）→ 决定 ship。Scope 见 [`docs/todo/v0.6.2.md`](todo/v0.6.2.md)。

## Current Version

v0.6.1（已 ship）→ 开发中：v0.6.2（实现完成，待自测 + ship）

## In-flight Changes

v0.6.2 (#80-#88) 全部落地 2026-04-26：

- ✅ HotkeyTrigger enum：5 候选 + keycode 映射（spike #81 验证可靠）
- ✅ HotkeyMonitor：rename FnHotkeyMonitor + 通用化 + swap API + synthesized release
- ✅ AppState.pushToTalkTrigger + UserDefaults persist
- ✅ Settings 新 Hotkey tab：radio + Test 指示灯（绑 `state.triggerKeyHeld`）+ Reset
- ✅ AppDelegate：observe state → `hotkeyMonitor.swap(to:)`；rename fnMonitor / handleFn
- ✅ HotkeyTriggerTests + HotkeyMonitorSwapTests（12 tests）
- ✅ README + CHANGELOG Unreleased

## Next Concrete Step

`make build` 装本地、跑 Settings → Hotkey 自测：(1) 切换到 Right Option，按右 Option 键看指示灯亮 + 录音触发；(2) F13/F14 在外接键盘上验证（如果有）；(3) Reset 按钮回 Fn。然后开 release 收尾（Info.plist bump 0.6.2/19 + devlog + `make release`）。

## Blockers / Open Questions

- Right modifier keycode 区分可靠性（待 #81 spike 验证）
- F13/F14 在常规笔记本无、外接键盘各家映射不同 → Test 指示灯是 UX guard
- v0.6.1 dogfood 攒数据：100 KB/s 阈值 + 5x 倍率定稿、hf-mirror 命中率
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
