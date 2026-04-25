# Changelog

本项目所有**面向用户**的变更记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## Unreleased

_（下个版本的用户可见变更在此累积）_

## v0.6.1 — 2026-04-26

### Added
- **首次启动 onboarding**：装好后启动会弹一次确认对话框，提示下载默认模型 (Qwen3-ASR 1.7B, ~1.4 GB)。点 "Later" 可跳过，之后从 **Settings → Manage Models** 手动下载任意模型。既有用户（已有缓存模型）不会被再问
- **HuggingFace 自动镜像兜底**：启动时自动测速，若官方 HF 慢/不通则切到 `hf-mirror.com`。零配置、零账号、零环境变量。中国大陆用户开箱即用

### Fixed
- Settings → Manage Models 的当前 backend 行在"未下载模型"状态下不再误显示 "Active" / "Preparing…"；现在显示真实状态 ("Not downloaded" + "Download" 按钮)，按 Fn 时也会准确提示而不是 "still loading"

### Notes
- 模型仍存在 `~/Library/Application Support/VoiceTyping/models/`；Sparkle 升级**不会**重新下载模型（只换 `.app`）
- 如果你的网络通过 VPN/代理（如 clash），且日志显示 probe 持续 TLS 失败：把 `huggingface.co` 和 `hf-mirror.com` 加 DIRECT 规则即可

## v0.6.0.3 — 2026-04-25

### Notes
- 内部 dummy build：用于跑通 v0.6.0.2 → v0.6.0.3 的 Sparkle 真升级链路（detect → EdDSA 验签 → 替换 → 重启 → TCC 保留），验证通过。无 user-facing 改动

## v0.6.0.2 — 2026-04-25

### Fixed
- **Sparkle 自动更新链路修复**：v0.6.0 / v0.6.0.1 的 DMG 因 Sparkle helper 签名问题（自签证书 + `--deep` codesign 把 Sparkle 内部 XPC helper 一起重签了，破坏 IPC）无法走 Sparkle 升级。**装着 v0.6.0 / v0.6.0.1 的请手动下载 v0.6.0.2 DMG 拖进 Applications 一次**——之后所有版本的 Sparkle 自更新恢复正常

### Notes
- 无 user-facing 功能改动；仅修发版基础设施

## v0.6.0.1 — 2026-04-25

### Notes
- 内部 dummy build：用于验证 Sparkle 升级链路（v0.6.0 → v0.6.0.1）。链路没跑通，根因暴露后由 v0.6.0.2 修复

## v0.6.0 — 2026-04-24

### Added
- **DMG 安装包**：从 [Releases](https://github.com/016hiro/voice_typing/releases) 下载 `VoiceTyping-0.6.0.dmg`，双击 → 拖到 Applications → 首次右键 → 打开（绕过 Gatekeeper 一次）
- **Sparkle 自更新**：装好之后所有版本无感升级。启动时自动检查 + 每 24h 后台检查 + 菜单 "Check for Updates…" 手动触发。EdDSA 签名验证 update 完整性
- **PolyForm Noncommercial 1.0.0 LICENSE**：source-available，个人 / 教育 / 研究 / 非营利使用 OK；禁商用
- **Hands-free 模式**（Settings → Models, EXPERIMENTAL，原 v0.5.3 工作）：开启后短按 Fn（< 200ms）= 录音继续，1.5 秒静默自动停。再按 Fn = 取消丢弃。长按 Fn 行为不变。仅 Qwen 后端可用，所有 3 种 transcription timing 都支持。默认关闭 (dogfood opt-in)
- 胶囊 hands-free 视觉：morse 染橙 + "HF" 角标 + 进入时显示 "TAP FN TO CANCEL" 3 秒

### Changed
- 录音时长 cap 抽到单一来源 `RecordingPolicy.maxDuration(timing:backend:)`：live + Qwen = 600s，其他 = 60s。hands-free 共用同一规则

### Fixed
- **DebugCaptureWriter `meta.json` 缺失**：v0.5.2 dogfood 12% 完整率 → 现在 begin() 立刻写 partial meta，crash/force-quit 也能保留元数据
- **DebugCaptureWriter timestamp 秒精度**：`live_drain.py` 因为 `endedAt` 和 last inject 经常落同一秒报 0ms drain 全失效，现在 ISO8601 加 fractional seconds

### Notes
- v0.5.3 的全部代码工作（hands-free + writer 修补 + RecordingPolicy）从未发过 binary release，全部 fold 进 v0.6.0 首发
- 没有 Apple Developer 账号 → 没有 notarization → 首次启动 Gatekeeper 会拦，需要右键 → 打开。详见 [README "Install" 段](README.md#install-v060-prebuilt-dmg)
- 详细技术 + 决策见 [`docs/devlog/v0.6.0.md`](docs/devlog/v0.6.0.md)

## v0.5.2 — 2026-04-23

### Added
- **Transcription timing 设置**：Settings → Models 新增三选一选项 ("After recording — one shot" / "After recording — segmented" / "While speaking — live")。Live 模式（v0.5.0 起隐藏在 `defaults write liveStreamingEnabled`）现在有显式 UI 入口
- **行卡片设计 + chip 标签**：每个选项配 DEFAULT/QWEN/EXPERIMENTAL 小标签；hover 显示详细说明 tooltip；非 Qwen backend 时只灰掉 segmented + live 两行（one-shot 仍可用）
- **`Scripts/analysis/`**：5 个 Python stdlib-only 分析脚本读 debug-captures——`summary.py` / `hallucination_review.py` / `live_drain.py` / `focus_drop.py` / `segment_latency.py`。零依赖，`python3 summary.py "$ROOT"` 直接跑

### Changed
- 移除 Settings → Models 顶部 "Speech Recognition Model" 标题 + 底部 cache 路径说明，腾空间给 Transcription timing 卡片
- 旧的 `defaults write streamingEnabled` / `defaults write liveStreamingEnabled` 仍然有效（UserDefaults 是 Picker 的 backing store），不需要任何迁移操作
