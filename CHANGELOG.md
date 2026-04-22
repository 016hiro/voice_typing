# Changelog

本项目所有**面向用户**的变更记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## Unreleased
- _（下个版本的用户可见变更在此累积）_

## v0.5.2 — 2026-04-23

### Added
- **Transcription timing 设置**：Settings → Models 新增三选一选项 ("After recording — one shot" / "After recording — segmented" / "While speaking — live")。Live 模式（v0.5.0 起隐藏在 `defaults write liveStreamingEnabled`）现在有显式 UI 入口
- **行卡片设计 + chip 标签**：每个选项配 DEFAULT/QWEN/EXPERIMENTAL 小标签；hover 显示详细说明 tooltip；非 Qwen backend 时只灰掉 segmented + live 两行（one-shot 仍可用）
- **`Scripts/analysis/`**：5 个 Python stdlib-only 分析脚本读 debug-captures——`summary.py` / `hallucination_review.py` / `live_drain.py` / `focus_drop.py` / `segment_latency.py`。零依赖，`python3 summary.py "$ROOT"` 直接跑

### Changed
- 移除 Settings → Models 顶部 "Speech Recognition Model" 标题 + 底部 cache 路径说明，腾空间给 Transcription timing 卡片
- 旧的 `defaults write streamingEnabled` / `defaults write liveStreamingEnabled` 仍然有效（UserDefaults 是 Picker 的 backing store），不需要任何迁移操作
