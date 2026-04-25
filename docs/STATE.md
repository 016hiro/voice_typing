# STATE

_Last updated: 2026-04-25 17:00_

## Current Focus

v0.6.0 系列已全闭环（v0.6.0 + v0.6.0.1 + v0.6.0.2 + v0.6.0.3）：DMG 分发 + Sparkle 自更新链路用 v0.6.0.2 → v0.6.0.3 真验证通过（#72 close）。期间清掉 CI 5 个版本的 silent red + 装了 Stop hook gate 防再犯。下一版 v0.6.1 scope 待拍板（[`docs/todo/v0.6.1.md`](todo/v0.6.1.md) 占位）。

## Current Version

v0.6.1（scope 待拍板）

## In-flight Changes

无 in-flight。v0.6.0 系列 close 完毕，三件关键文档：

- 收尾段：[`docs/devlog/v0.6.0.md`](devlog/v0.6.0.md) 末尾 close-iteration block
- 用户面变更：[`CHANGELOG.md`](../CHANGELOG.md) v0.6.0.1/2/3 entries
- 下版本占位：[`docs/todo/v0.6.1.md`](todo/v0.6.1.md)

## Next Concrete Step

填 `docs/todo/v0.6.1.md` 的 scope（用户来定主题）。候选池见该文档末尾。

## Blockers / Open Questions

- v0.6.1 scope 待用户拍板（无 blocker，待输入）
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积，不卡版本节奏）
- `#34` ship v0.5.1 大概率 obsolete（v0.5.x 全 fold 进 v0.6.0），建议确认 scope 时一并 close
