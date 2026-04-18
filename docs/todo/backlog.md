# Backlog

未排进具体版本，按价值/成本评估后再分配。

## 短期

### 体验

- [ ] **首次启动检测不完整模型**：启动时如果 `models/.../AudioEncoder.mlmodelc/weights/weight.bin` 缺失或大小异常，自动清理那个 mlmodelc 子目录让 WhisperKit 重下，避免半成品状态卡死。
- [ ] **录音时长视觉提示**：接近 60 s 上限时胶囊文字提示倒计时。
- [ ] **WhisperKit 下载进度**：当前是 indeterminate。看 upstream 能不能提供细粒度回调。

### 开发流程

- [ ] **稳定签名（解决 TCC 重新授权问题）**：`make setup-cert` 创建本地自签名证书 → `make build` 用它签名。这样 cdhash 跨重建稳定，TCC 授权不丢。详见 devlog v0.1.0 issue 7。
- [ ] **`make reset-perms` target**：`tccutil reset Accessibility com.voicetyping.app && tccutil reset Microphone com.voicetyping.app`，开发期一键重置。
- [ ] **CI 检查**：GitHub Actions 跑 `swift build` + `swift test`（目前还没单元测试）。

### 功能扩展

- [ ] **快捷键可配置**：除 Fn 外提供 Right Option / Right Cmd 等替代方案；Settings 窗口加 hotkey picker。
- [ ] **历史转录记录**：可选保存最近 N 条转录到 Settings → History 标签，支持复制/重新发送。

> 多模型切换已落地在 v0.2.0，详见 [v0.2.0.md](v0.2.0.md)。自定义词典 + 四档 refiner 已落地在 v0.3.0，详见 [v0.3.0.md](v0.3.0.md)。Per-app 上下文 profile 已落地在 v0.3.1，详见 [../devlog/v0.3.1.md](../devlog/v0.3.1.md)。

## 中期 (v0.4+)

- [ ] ~~**中英自动语种检测**~~：Qwen3-ASR 原生就支持中英混合输入（2026-04-18 实测 zh-CN hint 下混读英文仍转写正确）。保留 Whisper backend 的场景：它 code-switch 弱，仍需要语言选择 UI。v0.4.0 不再拿它做主线。
- [ ] **流式转录**：长录音边录边出文，胶囊实时显示部分结果。Qwen-0.6B 的 92ms TTFT 在这里才真正有用。
- [ ] **VAD 自动停止**：除 Fn 松开外，检测到长时间静默自动结束录音。
- [ ] **更多 ASR 后端**：
  - whisper.cpp 实现（Intel Mac 支持 + 量化模型选项）
  - Apple SFSpeechRecognizer 实现（无依赖、零下载、低延迟，但中英混杂效果差）
  - OpenAI Whisper API 实现（云端、最高准确度、需 key）
- [ ] **多 LLM 支持**：Claude / Gemini / 本地 Ollama 等。`LLMRefiner` 抽象成协议，多实现。
- [ ] **本地 MLX refiner**：v0.5.0 候选，摆脱 API key 依赖。

## 长期 / 想法池

- [ ] 跨平台（Windows / Linux）— 需要重写 hotkey + audio + injection 三层
- [ ] 通知中心 widget / 实时听写浮窗
- [ ] 语音命令模式（说"打开 Safari"触发动作）—— v0.6.0 候选
- [ ] App Store 发行：需要正式签名 + sandbox 适配（TIS、CGEventTap 在 sandbox 下不可用 → 改成 helper agent 架构）

## v0.3.0 派生 / 后续优化

- [ ] **upstream issue：`soniqo/speech-swift` 空 buffer 崩溃**：`WhisperFeatureExtractor.extractFeatures` 对 `audio.count == 0` 会索引越界（`AudioPreprocessing.swift:180` 的 `audio[max(0, -1)]`）。本地已在三层 guard 规避，但需要上报 upstream 加 `guard !audio.isEmpty`。
- [ ] **字典搜索 / 排序 UI**：条目 > 50 之后需要。
- [ ] **字典中文 substring 匹配的误判**："超配森" 算 "配森" 命中会歪 LRU；v0.3 发布后看 stats 再定。
- [ ] **未配 API key 时的 UI 提示**：refine mode 非 off 但 credentials 为空时，在 LLM tab / 胶囊显示 "API key missing — pronunciation rewrites won't work"。
- [ ] **v0.3.0 端到端验证矩阵**：4 × RefineMode × 20 条中英输入盲测打分；Raw-first 三分支；budget 边界；JSON 外编辑 + 重启；导入导出 roundtrip。详见 [v0.3.0.md](v0.3.0.md) 验证段。

## 已知 Bug（待修）

- 暂无已知未修 bug。所有 v0.1.0/v0.2.0/v0.3.0 期间发现的 bug 已修复，详见各 devlog。
