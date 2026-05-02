# STATE

_Last updated: 2026-05-02_

## Current Focus

**v0.7.1 ship 收尾中（2026-05-02 close-iteration 完毕，等 release ceremony）**

## Current Version

**v0.7.2**（skeleton，主线 #B5 per-app hotwords 待 `/think` 拍板）

已 ship 版本：v0.7.1 (2026-05-02) / v0.7.0 (2026-05-02) / v0.6.4 (2026-05-01) / v0.6.3 (2026-05-01)。

## In-flight Changes

代码 in-flight:
- v0.7.1 主线 4 commits (d514bce..7722d4d) 已在 main，待 close-iteration commit + Info.plist bump + push + tag + DMG

已完成的非代码工作:
- v0.7.1 close-iteration（devlog / CHANGELOG / 归档 todo / v0.7.2 skeleton with #B5 + dogfood 验证 criteria）

## Next Concrete Step

**v0.7.1 ship 收尾**：
1. close-iteration commit (devlog / CHANGELOG / todo files)
2. Info.plist bump：`CFBundleShortVersionString` → `0.7.1`，`CFBundleVersion` → 22
3. `make release` 出 DMG
4. `git push` + `gh release create v0.7.1`
5. 更新 appcast.xml 让 Sparkle 看到新版本

之后 dogfood 3-5 天验 v0.7.1 advancement criteria（keep-alive ticks 真在跑、≥5s outlier 回到 v0.6.1 baseline），同时 `/think` 拍 #B5 schema。

## Blockers / Open Questions

- **v0.7.1 keep-alive 实际是否生效** — App Nap 抑制 + wake hook + QoS 升级三件套是 prophylactic，dogfood 跑 `keep_alive.py` + `segment_latency.py` 验证。如不达标说明 App Nap 不是唯一根因，再深挖 Metal kernel cache eviction
- **#B5 schema 决策** — `ContextProfile.dictionaryFilter` 引用全局子集 vs 独立 PerAppDictionaryStore vs whitelist/blacklist enum；UI 也未拍
- v0.7.0 carry-over 仍 pending：`#R10` streaming integration tests / `#R11` 16 GB Mac dogfood / `replaceLastInjection` IME bypass —— 全在 backlog，dogfood 信号触发再合并
- v0.6.3 dogfood 攒数据：`refines.jsonl` cloud vs local 质量比对（`refine_quality.py` 已就位）
- `#33` dogfood live mode 5+ 天信号采集 仍 pending
