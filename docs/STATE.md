# STATE

_Last updated: 2026-04-25 17:30_

## Current Focus

v0.6.0 系列已全闭环（v0.6.0 + v0.6.0.1 + v0.6.0.2 + v0.6.0.3）：DMG 分发 + Sparkle 自更新链路用 v0.6.0.2 → v0.6.0.3 真验证通过（#72 close）。期间清掉 CI 5 个版本的 silent red + 装了 Stop hook gate 防再犯。**下一版号 + 主题待定**——先在 v0.6.0.3 上 dogfood 一段时间。

## Current Version

v0.6.0.3（已发布在 [GitHub Releases](https://github.com/016hiro/voice_typing/releases/tag/v0.6.0.3) + Sparkle appcast）

## In-flight Changes

无 in-flight。v0.6.0 系列 close 完毕，三件关键文档：

- 收尾段：[`docs/devlog/v0.6.0.md`](devlog/v0.6.0.md) 末尾 close-iteration block
- 用户面变更：[`CHANGELOG.md`](../CHANGELOG.md) v0.6.0.1/2/3 entries
- 发版经验沉淀：[`docs/release-process.md`](release-process.md) Known quirks（v0.6.0.x 4 个 footgun + verified 升级路径）

## Next Concrete Step

dogfood v0.6.0.3，攒真实使用信号 / 暴露遗漏 bug。下一版号（v0.6.1 patch / v0.7.0 主题 / 其他）等用户拍板再开 todo doc。

## Blockers / Open Questions

- 下一版主题待定（不卡，dogfood 期间观察）
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
