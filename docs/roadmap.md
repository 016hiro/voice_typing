# Roadmap

> 一页纸看现状 + 接下来 2-3 版主题。颗粒度比 [`todo/backlog.md`](todo/backlog.md) 粗、比单版 planning doc 粗，目的是给"现在大概在哪条线上"一个快速答案。
>
> 维护节奏：每个版本 ship 之后顺手更新当前 ship 行 + 把对应短期项移到「已完成」或下一版。

## 当前 ship

**v0.5.0** — 真 live-mic 流式 + force-split 25s。详见 [`devlog/v0.5.0.md`](devlog/v0.5.0.md)。

最近三个里程碑（按时间倒序）：
- **v0.5.0** — `LiveTranscriber` + 段级 incremental injection + force-split 10s → 25s
- **v0.4.5** — VAD 调参 (0.3/0.7) + `HallucinationFilter`（训练尾巴 + prompt echo）
- **v0.4.4** — Silero VAD 打 bundle + 胶囊去文本 + refine 默认 Off + Developer logging

完整历史见 [`devlog/`](devlog/) 目录。

## 短期 (v0.5.x)

主题：**live mode 落地 + 真实使用反馈驱动的 polish + 数据基础设施**

- **v0.5.1** — 四条线并进：(1) UX 小补丁（首次启动检测、录音时长提示）(2) 性能基线（Qwen 加载量化 + 修上游 weights 双读 + 三 backend × 全 fixture 速度 benchmark）(3) Debug 数据捕获 toggle（用户开了之后录音/转写/注入全数据落盘，便于回溯分析；范围待讨论）(4) Live mode dogfood gate（不引入 live 新特性，攒真实数据给 v0.5.2 输入）。详见 [`todo/v0.5.1.md`](todo/v0.5.1.md)。
- **v0.5.2** — VAD auto-stop + Live mode Settings UI 暴露（dogfood 验证后）。Live + refine 组合的设计落定。Debug capture 分析工具（CLI 子命令）。

## 中期 (v0.6+)

主题候选（具体顺序看 v0.5.x 数据再定）：

- **多 LLM 后端**：`LLMRefiner` 抽象成协议；Claude / Gemini / 本地 Ollama 实现。
- **本地 MLX refiner**：v0.5.0 里曾被点名为候选，但优先级让位给了 live mic。摆脱 API key 依赖，零网络可用。
- **更多 ASR 后端**：whisper.cpp（Intel Mac 支持 + 量化）、Apple SFSpeechRecognizer（无依赖、低延迟，中英混读弱）、OpenAI Whisper API（云端最准、需 key）。
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
