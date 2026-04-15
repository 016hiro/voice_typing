# Backlog

未排进具体版本，按价值/成本评估后再分配。

## 短期 (v0.2.0 候选)

### 体验

- [ ] **下载进度展示到菜单栏**：当前 `RecognizerState.loading(progress:)` 是 indeterminate (-1)。接 WhisperKit 的下载进度回调（如可用），把 % 写到菜单文字（"Preparing model… 42%"）。
- [ ] **首次启动检测不完整模型**：启动时如果 `models/.../AudioEncoder.mlmodelc/weights/weight.bin` 缺失或大小异常，自动清理那个 mlmodelc 子目录让 WhisperKit 重下，避免半成品状态卡死。
- [ ] **录音时长视觉提示**：接近 60 s 上限时胶囊文字提示倒计时。

### 开发流程

- [ ] **稳定签名（解决 TCC 重新授权问题）**：`make setup-cert` 创建本地自签名证书 → `make build` 用它签名。这样 cdhash 跨重建稳定，TCC 授权不丢。详见 devlog v0.1.0 issue 7。
- [ ] **`make reset-perms` target**：`tccutil reset Accessibility com.voicetyping.app && tccutil reset Microphone com.voicetyping.app`，开发期一键重置。
- [ ] **CI 检查**：GitHub Actions 跑 `swift build` + `swift test`（目前还没单元测试）。

### 功能扩展

- [ ] **快捷键可配置**：除 Fn 外提供 Right Option / Right Cmd 等替代方案；Settings 窗口加 hotkey picker。
- [ ] **历史转录记录**：可选保存最近 N 条转录到 Settings → History 标签，支持复制/重新发送。

> 多模型切换已提升为 v0.2.0 主线，详见 [v0.2.0.md](v0.2.0.md)。

## 中期 (v0.3+)

- [ ] **流式转录**：长录音边录边出文，胶囊实时显示部分结果。Qwen-0.6B 的 92ms TTFT 在这里才真正有用。
- [ ] **VAD 自动停止**：除 Fn 松开外，检测到长时间静默自动结束录音。
- [ ] **更多 ASR 后端**（v0.2.0 之后的扩展）：
  - whisper.cpp 实现（Intel Mac 支持 + 量化模型选项）
  - Apple SFSpeechRecognizer 实现（无依赖、零下载、低延迟，但中英混杂效果差）
  - OpenAI Whisper API 实现（云端、最高准确度、需 key）
- [ ] **多 LLM 支持**：Claude / Gemini / 本地 Ollama 等。`LLMRefiner` 抽象成协议，多实现。
- [ ] **自定义系统词典**：用户可加私有名词（人名、项目名、公司名）注入到 ASR prompt 或 LLM system prompt，提升专有名词识别率。

## 长期 / 想法池

- [ ] 跨平台（Windows / Linux）— 需要重写 hotkey + audio + injection 三层
- [ ] 通知中心 widget / 实时听写浮窗
- [ ] 语音命令模式（说"打开 Safari"触发动作）
- [ ] App Store 发行：需要正式签名 + sandbox 适配（TIS、CGEventTap 在 sandbox 下不可用 → 改成 helper agent 架构）

## 已知 Bug（待修）

- 暂无已知未修 bug。所有 v0.1.0 期间发现的 bug 已修复，详见 [devlog/v0.1.0.md](../devlog/v0.1.0.md)。
