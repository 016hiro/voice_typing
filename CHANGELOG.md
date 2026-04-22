# Changelog

本项目所有**面向用户**的变更记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## Unreleased

### Added
- **Hands-free 模式**（Settings → Models, EXPERIMENTAL）：开启后短按 Fn（< 200ms）= 录音继续，1.5 秒静默自动停。再按 Fn = 取消丢弃。长按 Fn 行为不变。仅 Qwen 后端可用，所有 3 种 transcription timing 都支持。默认关闭 (dogfood opt-in)
- 胶囊 hands-free 视觉：morse 染橙 + "HF" 角标 + 进入时显示 "TAP FN TO CANCEL" 3 秒

### Changed
- 录音时长 cap 抽到单一来源 `RecordingPolicy.maxDuration(timing:backend:)`：live + Qwen = 600s，其他 = 60s。hands-free 共用同一规则

### Fixed
- **DebugCaptureWriter `meta.json` 缺失**：v0.5.2 dogfood 12% 完整率 → 现在 begin() 立刻写 partial meta，crash/force-quit 也能保留元数据
- **DebugCaptureWriter timestamp 秒精度**：`live_drain.py` 因为 `endedAt` 和 last inject 经常落同一秒报 0ms drain 全失效，现在 ISO8601 加 fractional seconds

## v0.5.2 — 2026-04-23

### Added
- **Transcription timing 设置**：Settings → Models 新增三选一选项 ("After recording — one shot" / "After recording — segmented" / "While speaking — live")。Live 模式（v0.5.0 起隐藏在 `defaults write liveStreamingEnabled`）现在有显式 UI 入口
- **行卡片设计 + chip 标签**：每个选项配 DEFAULT/QWEN/EXPERIMENTAL 小标签；hover 显示详细说明 tooltip；非 Qwen backend 时只灰掉 segmented + live 两行（one-shot 仍可用）
- **`Scripts/analysis/`**：5 个 Python stdlib-only 分析脚本读 debug-captures——`summary.py` / `hallucination_review.py` / `live_drain.py` / `focus_drop.py` / `segment_latency.py`。零依赖，`python3 summary.py "$ROOT"` 直接跑

### Changed
- 移除 Settings → Models 顶部 "Speech Recognition Model" 标题 + 底部 cache 路径说明，腾空间给 Transcription timing 卡片
- 旧的 `defaults write streamingEnabled` / `defaults write liveStreamingEnabled` 仍然有效（UserDefaults 是 Picker 的 backing store），不需要任何迁移操作
