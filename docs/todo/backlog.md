# Backlog

未排进具体版本，按价值/成本评估后再分配。

## 短期

### 体验

- [ ] **首次启动检测不完整模型**：启动时如果 `models/.../AudioEncoder.mlmodelc/weights/weight.bin` 缺失或大小异常，自动清理那个 mlmodelc 子目录让 WhisperKit 重下，避免半成品状态卡死。
- [ ] **录音时长视觉提示**：接近 60 s 上限时胶囊文字提示倒计时。
- [ ] **WhisperKit 下载进度**：当前是 indeterminate。看 upstream 能不能提供细粒度回调。

### 开发流程

- [x] ~~**稳定签名（解决 TCC 重新授权问题）**：`make setup-cert` 创建本地自签名证书 → `make build` 用它签名。这样 cdhash 跨重建稳定，TCC 授权不丢。~~ 已在 v0.4.1 落地，详见 [../devlog/v0.4.1.md](../devlog/v0.4.1.md)。
- [x] ~~**`make reset-perms` target**~~ 已在 v0.4.1 落地。
- [x] ~~**CI 检查**：GitHub Actions 跑 `swift build`~~ 已在 v0.4.1 落地。`swift test --skip E2E` 已在 v0.4.3 加进 CI。
- [x] ~~**回归测试台**：固定 fixture WAV，每次 ASR 改动跑 batch + streaming 对比~~ 已在 v0.4.3 落地（`make test` / `make test-e2e`，JFK PD 英文 + 9 条 LibriSpeech + 用户录中文），详见 [../devlog/v0.4.3.md](../devlog/v0.4.3.md)。

### 功能扩展

- [ ] **快捷键可配置**：除 Fn 外提供 Right Option / Right Cmd 等替代方案；Settings 窗口加 hotkey picker。
- [ ] **历史转录记录**：可选保存最近 N 条转录到 Settings → History 标签，支持复制/重新发送。

> 多模型切换已落地在 v0.2.0，详见 [v0.2.0.md](v0.2.0.md)。自定义词典 + 四档 refiner 已落地在 v0.3.0，详见 [v0.3.0.md](v0.3.0.md)。Per-app 上下文 profile 已落地在 v0.3.1，详见 [../devlog/v0.3.1.md](../devlog/v0.3.1.md)。API key Keychain 迁移 + 稳定签名 + CI 已落地在 v0.4.1，详见 [../devlog/v0.4.1.md](../devlog/v0.4.1.md)。Post-record 流式 (opt-in experimental) 已落地在 v0.4.2，详见 [../devlog/v0.4.2.md](../devlog/v0.4.2.md)。Unit + E2E ASR 回归测试台已落地在 v0.4.3，详见 [../devlog/v0.4.3.md](../devlog/v0.4.3.md)。VAD bundle 预装 + 胶囊去文本 + refine 默认 Off + Advanced 设置 (Developer logging) 已落地在 v0.4.4，详见 [../devlog/v0.4.4.md](../devlog/v0.4.4.md)。VAD 调参 (minSpeech 0.3 / minSilence 0.7) + HallucinationFilter (训练尾巴 + prompt echo) 已落地在 v0.4.5，详见 [../devlog/v0.4.5.md](../devlog/v0.4.5.md)。

## 中期 (v0.4+)

- [ ] ~~**中英自动语种检测**~~：Qwen3-ASR 原生就支持中英混合输入（2026-04-18 实测 zh-CN hint 下混读英文仍转写正确）。保留 Whisper backend 的场景：它 code-switch 弱，仍需要语言选择 UI。v0.4.0 不再拿它做主线。
- [x] ~~**流式转录 (post-record)**~~：v0.4.2 落地 opt-in experimental，VAD 分段 + 段级 Qwen 转写 + progressive 胶囊显示。详见 [../devlog/v0.4.2.md](../devlog/v0.4.2.md)。真 live-mic 留到下一项。
- [ ] **真 live-mic 流式**（v0.5 / Step 3 候选）：v0.4.2 是 post-record（Fn 松开后才开始逐段吐）；live 要 AudioRecorder 边录边推 chunk 给 `StreamingVADProcessor`，`.speechEnded` 触发 `Qwen3ASRModel.transcribe`。需要解 `AudioCapture.maxDuration` 60s 硬限 + 段级取消语义 + Fn 中途松开对 in-flight 段的 ACK。
- [ ] **VAD 自动停止**（live-mic 副产品）：除 Fn 松开外，检测到长时间静默自动结束录音。v0.5 live mic 稳定后评估。
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

## v0.3.2 review / v0.4.1 遗留（Step 2 收）

以下在 v0.4.1 评估过、**明确不做**的项，留给 v0.4.0 streaming（Step 2）或后续 patch release：

- [ ] **Dictionary/Profiles Table `.id(xxxTick)` rebuild 吃 scroll/selection**：每次 tick bump 整个 NSTableView 重建，丢滚动位置和选中状态。改为让 store 发布 `@Published var snapshot: [T]` 避免重建。
- [ ] **Raw-first 的 ⌘Z 会撤销用户中间键入**：raw paste 后、refined 还没回来时用户手动打了字，replace-injection 的 ⌘Z 撤销的是用户打字。需要检测 intra-app edits（timestamp / clipboard 对比）。
- [ ] **模型下载中切 backend 不取消网络请求**：`backendSwapTask?.cancel()` 只取消 Task，HuggingFace snapshot 不响应 `Task.isCancelled`。下载继续，结果被丢弃。
- [ ] **FnHotkeyMonitor 的 event tap 权限撤销检测**：tap 被 OS `tapDisabledByTimeout` 时会自动 re-enable，但 Accessibility 权限被撤销时 tap create 成功但 callback 不触发。需要定期 sanity check。
- [ ] **未配 API key 时的 UI 提示**：refine mode 非 off 但 credentials 为空时，LLM tab 或胶囊显示 "API key missing"。v0.4.1 的 Keychain 迁移把这块的 UX 边缘情况放大了（迁移失败 alert "Later" 之后会静默 fail-open）。
- [ ] **LLMRefiner 共享 URLSession**：v0.4.1 评估砍掉（无 delegate 不漏 session、keep-alive 收益小）。若将来实测 Raw-first 下 replace 延迟明显再做。

## 已知 Bug（待修）

- 暂无已知未修 bug。所有 v0.1.0–v0.4.1 期间发现的 bug 已修复，详见各 devlog。
