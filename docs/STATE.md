# STATE

_Last updated: 2026-05-02_

## Current Focus

**v0.7.0 ship 完毕（2026-05-02），下一步 v0.7.1 待 dogfood 信号。**

## Current Version

**v0.7.1**（skeleton，待 v0.7.0 ship 后 5 天 dogfood 反馈再排主线）。

已 ship 版本：v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

代码 in-flight:
- 无（v0.7.0 close 完毕，v0.7.1 待开工）

已完成的非代码工作:
- v0.7.0 close-iteration（devlog / CHANGELOG / 归档 todo / 创建 v0.7.1 skeleton / backlog 迁入 #R10/#R11/IME bypass）
- v0.7.0 主线 13 commits (a9c88bc..8e76528) 全部上 main，13 ahead origin/main 待 push

## Next Concrete Step

**v0.7.0 ship 收尾**（close-iteration 之外的 release ceremony）：
1. Info.plist bump：`CFBundleShortVersionString` → `0.7.0`，`CFBundleVersion` 自增
2. `make release` 出 DMG
3. `git push` + `gh release create v0.7.0`
4. 更新 appcast.xml 让 Sparkle 看到新版本

之后 5 天 dogfood，从 backlog 拉 v0.7.1 主线工作。

## Blockers / Open Questions

- v0.7.0 dogfood 反馈待收（流式 inject 在前 5 个常用 app 是否 regression / Live × Refine per-segment context 模型是否漂移）
- 16 GB Mac 真实数据待 dogfood（baseline.md 是从 24 GB 外推的）；v0.7.0 新增 `LocalLiveSegmentSession` KV cache 累积可能加剧 swap
- `replaceLastInjection` IME bypass（live cloud Cmd+Z + CJK 拦截）—— 已在 backlog，dogfood 报告再修
- **v0.6.4 K4 manual 验证**：`vmmap $(pgrep VoiceTyping)` 看 MLX region 长期 active；dogfood 一周后看 `tail asr_ms` 分布有无 9s+ outlier
- v0.6.3 dogfood 攒数据：本地 refiner cold-decompress 真实分布、`refines.jsonl` cloud vs local 质量比对
- `#33` dogfood live mode 5+ 天信号采集 仍 pending（持续累积）
