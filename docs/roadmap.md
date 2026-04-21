# Roadmap

> 一页纸看现状 + 接下来 2-3 版主题。颗粒度比 [`todo/backlog.md`](todo/backlog.md) 粗、比单版 planning doc 粗，目的是给"现在大概在哪条线上"一个快速答案。
>
> 维护节奏：每个版本 ship 之后顺手更新当前 ship 行 + 把对应短期项移到「已完成」或下一版。

## 当前 ship

**v0.5.1** — 性能基线 instrument + dl_init 修 (cached prepare 5s → ~1s) + Debug capture toggle + UX 补丁。详见 [`devlog/v0.5.1.md`](devlog/v0.5.1.md)。

最近三个里程碑（按时间倒序）：
- **v0.5.1** — 性能基线 instrument + dl_init 修 + Debug capture toggle + 首次启动检测 + 录音时长提示
- **v0.5.0** — `LiveTranscriber` + 段级 incremental injection + force-split 10s → 25s
- **v0.4.5** — VAD 调参 (0.3/0.7) + `HallucinationFilter`（训练尾巴 + prompt echo）

完整历史见 [`devlog/`](devlog/) 目录。

## 短期 (v0.5.x)

主题：**live mode 落地 + 真实使用反馈驱动的 polish + 数据基础设施**

- **v0.5.1** ✅ — 性能基线 instrument + dl_init 修 + Debug capture toggle + 首次启动检测 + 录音时长提示。7 项 Debug capture 决策全部锁定；B (修上游双读) 实测 <1% 占比，改为修 dl_init (HF HEAD 检查)。详见 [`devlog/v0.5.1.md`](devlog/v0.5.1.md) + [`todo/v0.5.1.md`](todo/v0.5.1.md)。
- **v0.5.2** — Live mode Settings UI 公开（把 `liveStreamingEnabled` 从 UserDefaults-hidden 抬到 Settings → Models，同时把 "Streaming" 改名 "Post-record streaming" 避免与 Live 撞概念）+ `Scripts/analysis/` 4 个 Python stdlib 分析脚本前置 + dogfood 驱动 polish（TBD by data）。详见 [`todo/v0.5.2.md`](todo/v0.5.2.md)。
- **v0.5.3** — VAD auto-stop / Hands-free 模式（tap Fn → 录音 → 检测长静默自停）。单独成版本因为需要 tap-vs-hold 检测 + 模式状态 UI + abort 手势等专门的 UX 设计，不适合混在 Live UI 公开里。

## 中期 (v0.6+)

主题候选（具体顺序看 v0.5.x 数据再定）：

- **v0.6.0 候选：多 backend streaming 抽象 + 更多 ASR backend**：`LiveTranscriber` 从硬类型 `QwenASRRecognizer` 抽象到 `SpeechRecognizer` 协议，协议补 `transcribeSegment` 同步入口。落地后打开的 backend：WhisperKit streaming（原生 Apple 栈，补 streaming hook 即可）、whisper.cpp（Intel Mac + 量化）、Apple SFSpeechRecognizer（零依赖、极低延迟、中英混读弱）、OpenAI Whisper API（云端、需 key）。连贯主题："backend 多样化 + streaming 一致化"。
- **Refine 专版**（暂记 v0.5.4 或 v0.6.x）：Live + refine 组合设计落定（Cmd+Z chain 跨 N 段的替代方案）+ refine I/O capture 补齐 + 多 LLM backend（Claude / Gemini / 本地 Ollama）。目前 v0.5.0+ 是 live mode 跳过 refine。
- **本地 MLX refiner**：v0.5.0 曾被点名为候选，优先级让位给 live mic。摆脱 API key 依赖，零网络可用。挂在 Refine 专版一起做或独立主题。
- **快捷键可配置 + 历史转录**：纯 UX，用户多了之后会需要。

## 长期 / 想法池

- 跨平台（Windows / Linux）—— 需要重写 hotkey + audio + injection 三层
- 通知中心 widget / 实时听写浮窗
- 语音命令模式（"打开 Safari"触发动作）
- App Store 发行（需要正式签名 + sandbox 适配 → helper agent 架构）

详见 [`todo/backlog.md`](todo/backlog.md) "长期 / 想法池" 段。

## 文档导航

| 想看什么 | 看哪 |
|---|---|
| 这个版本到底改了什么、为什么 | [`devlog/vX.X.X.md`](devlog/) |
| 下个版本计划做什么、范围多大 | [`todo/vX.X.X.md`](todo/) |
| 还没排版本、想到啥扔啥 | [`todo/backlog.md`](todo/backlog.md) |
| 整体技术架构（模块依赖、协议） | [`architecture.md`](architecture.md) |
| 现在大概在哪条线上 | 本文 |
