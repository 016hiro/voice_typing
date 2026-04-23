# Backlog

未排进具体版本，按价值/成本评估后再分配。

## 短期

### 体验

- [x] ~~**首次启动检测不完整模型**~~：v0.5.1 落地。`ModelStore.isComplete` + `repairIfIncomplete`，Whisper 粒度到单个 mlmodelc，Qwen 粒度到 variant 子目录。详见 [../devlog/v0.5.1.md](../devlog/v0.5.1.md)。
- [x] ~~**录音时长视觉提示**~~：v0.5.1 落地。`state.capsuleOverlayText` 驱动"Xs left" flash，live/batch 分别 60s/10s 警告窗口。详见 [../devlog/v0.5.1.md](../devlog/v0.5.1.md)。
- [ ] **WhisperKit 下载进度**：当前是 indeterminate。看 upstream 能不能提供细粒度回调。

### 开发流程

- [x] ~~**稳定签名（解决 TCC 重新授权问题）**：`make setup-cert` 创建本地自签名证书 → `make build` 用它签名。这样 cdhash 跨重建稳定，TCC 授权不丢。~~ 已在 v0.4.1 落地，详见 [../devlog/v0.4.1.md](../devlog/v0.4.1.md)。
- [x] ~~**`make reset-perms` target**~~ 已在 v0.4.1 落地。
- [x] ~~**CI 检查**：GitHub Actions 跑 `swift build`~~ 已在 v0.4.1 落地。`swift test --skip E2E` 已在 v0.4.3 加进 CI。
- [x] ~~**回归测试台**：固定 fixture WAV，每次 ASR 改动跑 batch + streaming 对比~~ 已在 v0.4.3 落地（`make test` / `make test-e2e`，JFK PD 英文 + 9 条 LibriSpeech + 用户录中文），详见 [../devlog/v0.4.3.md](../devlog/v0.4.3.md)。

### 功能扩展

- [ ] **快捷键可配置**：除 Fn 外提供 Right Option / Right Cmd 等替代方案；Settings 窗口加 hotkey picker。
- [ ] **历史转录记录**：可选保存最近 N 条转录到 Settings → History 标签，支持复制/重新发送。

> 多模型切换已落地在 v0.2.0，详见 [v0.2.0.md](v0.2.0.md)。自定义词典 + 四档 refiner 已落地在 v0.3.0，详见 [v0.3.0.md](v0.3.0.md)。Per-app 上下文 profile 已落地在 v0.3.1，详见 [../devlog/v0.3.1.md](../devlog/v0.3.1.md)。API key Keychain 迁移 + 稳定签名 + CI 已落地在 v0.4.1，详见 [../devlog/v0.4.1.md](../devlog/v0.4.1.md)。Post-record 流式 (opt-in experimental) 已落地在 v0.4.2，详见 [../devlog/v0.4.2.md](../devlog/v0.4.2.md)。Unit + E2E ASR 回归测试台已落地在 v0.4.3，详见 [../devlog/v0.4.3.md](../devlog/v0.4.3.md)。VAD bundle 预装 + 胶囊去文本 + refine 默认 Off + Advanced 设置 (Developer logging) 已落地在 v0.4.4，详见 [../devlog/v0.4.4.md](../devlog/v0.4.4.md)。VAD 调参 (minSpeech 0.3 / minSilence 0.7) + HallucinationFilter (训练尾巴 + prompt echo) 已落地在 v0.4.5，详见 [../devlog/v0.4.5.md](../devlog/v0.4.5.md)。真 live-mic 流式 + force-split 25s 已落地在 v0.5.0，详见 [../devlog/v0.5.0.md](../devlog/v0.5.0.md)。性能基线 instrument + dl_init 修 + Debug capture toggle + 首次启动检测 + 录音时长提示 已落地在 v0.5.1，详见 [../devlog/v0.5.1.md](../devlog/v0.5.1.md)。Transcription timing 三选一 Picker (行卡片设计) + 5 个 Python stdlib 分析脚本 (`Scripts/analysis/`) + devdoc 规范接入 已落地在 v0.5.2，详见 [../devlog/v0.5.2.md](../devlog/v0.5.2.md)。

## 中期 (v0.4+)

- [ ] ~~**中英自动语种检测**~~：Qwen3-ASR 原生就支持中英混合输入（2026-04-18 实测 zh-CN hint 下混读英文仍转写正确）。保留 Whisper backend 的场景：它 code-switch 弱，仍需要语言选择 UI。v0.4.0 不再拿它做主线。
- [x] ~~**流式转录 (post-record)**~~：v0.4.2 落地 opt-in experimental，VAD 分段 + 段级 Qwen 转写 + progressive 胶囊显示。详见 [../devlog/v0.4.2.md](../devlog/v0.4.2.md)。真 live-mic 留到下一项。
- [x] ~~**真 live-mic 流式**~~：v0.5.0 落地 `LiveTranscriber` + `AudioCapture.samples` 流 + VAD 预热 + per-segment lock；force-split 同时升 10 → 25s。隐藏 toggle (`liveStreamingEnabled` UserDefaults)，dogfood 一周后加 UI。详见 [../devlog/v0.5.0.md](../devlog/v0.5.0.md)。
- [x] ~~**VAD 自动停止 / Hands-free 模式**~~：v0.5.3 落地。tap Fn < 200ms → 录音 → 1.5s 静默自停 / 10s no-speech 自动取消 / 再 tap Fn 取消。Qwen-only × 全 3 种 timing 模式。默认 OFF（dogfood opt-in）。详见 [v0.5.3.md](v0.5.3.md)。阈值 dogfood 校准进 "数据驱动调研" 段。
- [ ] **更多 ASR 后端 + streaming 抽象**（v0.6.0 候选主题）：
  - `LiveTranscriber` 从硬类型 `QwenASRRecognizer` 抽象到 `SpeechRecognizer` 协议（前置）
  - `SpeechRecognizer` 协议补 `transcribeSegment` 同步入口（Qwen 已有 `transcribeSegmentSync`，Whisper 需要包一层）
  - WhisperKit streaming（post-record 先做，立即能 ship；live 依赖上面抽象完成）
  - whisper.cpp 实现（Intel Mac 支持 + 量化模型选项）
  - Apple SFSpeechRecognizer 实现（无依赖、零下载、低延迟，但中英混杂效果差）
  - OpenAI Whisper API 实现（云端、最高准确度、需 key）
- [ ] **多 LLM 支持 + Refine 专版**：`LLMRefiner` 抽象成协议，Claude / Gemini / 本地 Ollama 多实现。同版处理 Live + refine 组合设计（Cmd+Z chain 跨段问题）+ refine I/O capture（v0.5.1 punted）。
- [ ] **本地 MLX refiner**：v0.5.0 候选，摆脱 API key 依赖。挂在 Refine 专版一起做或独立主题。

## 长期 / 想法池

- [ ] 跨平台（Windows / Linux）— 需要重写 hotkey + audio + injection 三层
- [ ] 通知中心 widget / 实时听写浮窗
- [ ] 语音命令模式（说"打开 Safari"触发动作）—— v0.6.0 候选
- [ ] App Store 发行：需要正式签名 + sandbox 适配（TIS、CGEventTap 在 sandbox 下不可用 → 改成 helper agent 架构）

## 数据驱动调研 — 长期 不卡版本

> 这一段收**需要 dogfood 数据先到位才能决策**的事。不绑定具体版本，跑在主线版本节奏旁边，数据齐了 + 决策做了之后随便挂哪个 patch release 都行。
>
> 跟"长期 / 想法池"的区别：**这些是有明确产出物的**（"换方案 X / 调参数 Y"），只是当前缺数据；想法池是连方向都还在想的。

### Qwen 0.6B prompt echo 调研（v0.5.2 dogfood 数据揭示，v0.5.3 移出 scope）

**现象**：v0.5.2 dogfood 50 段里 20 段（**40%**）是 dictionary 列表 `'热词：Python、Qwen3-ASR、VAD、E2E、Rust。'` 的字面回显——HallucinationFilter 抓得准（误杀率 0%），但 echo 频率本身离谱（远高于 5% baseline）。

**观察**：
- 100% 落在 Qwen 0.6B（dogfood 没用 1.7B 数据可比）
- 集中在**短音频段**（多数 0.3-1.6s）
- 现有 user 100% 走 0.6B（自己挑的）

**候选方案**（按可能性 / 成本排）：

| 方案 | 描述 | 成本 | 风险 |
|---|---|---|---|
| (a) 短音频跳 dictionary prompt | < 2s 段不注入 dictionary 上下文 | 小 | dictionary 命中率下降 |
| (b) dictionary 改 logits bias | 不进 prompt 就不会被 echo | 大（要碰 ASR generation 层）| 兼容性 |
| (c) 默认升 1.7B | 0.6B 仅在 streaming 用 | 极小 | 加载时间 + 显存翻倍 |
| (d) HallucinationFilter 加 dictionary substring match | v0.5.2 已经做了 | 0 | 已生效 |

**决策依赖**：
1. 先跑 1.7B 一段时间看 echo rate 是否同样高（**这是当前阻塞**）
2. 测 (a) 方案 dictionary 命中率影响（数据齐后做）

**推断**：1.7B echo 显著低 → (c) 最简单，直接换默认。如果都高 → (a) 或 (b)。

**advancement criteria**：echo rate ≤ 10%（取决于选定方案）

### Hands-free 阈值校准（v0.5.3 dogfood 触发）

v0.5.3 拍板的 200ms tap 阈值 / 1.5s post-speech 静默 / 10s no-speech 自动取消，需要 dogfood 验证：

- tap 阈值是不是过严或过松（用户键盘 ergonomic 差异）
- 1.5s 静默是不是会卡断思考停顿
- 10s no-speech 是不是会误杀慢启动用户

**advancement criteria**：3 天 dogfood 0 严重投诉 → 不动；有投诉 → 调参 + 加 Settings 滑块

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
