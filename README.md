# VoiceTyping

A macOS menu-bar voice input app. Hold **Fn** to dictate, release to paste the transcribed text into the focused input field.

- Default language: Simplified Chinese (zh-CN). Also supports English, Traditional Chinese, Japanese, Korean.
- Swappable local ASR backend (select from the menu):
  - **Qwen3-ASR 1.7B** (MLX, ~1.4 GB) — SOTA open-source ASR, beats Whisper-large-v3 on multilingual benchmarks. Default when MLX is available.
  - **Qwen3-ASR 0.6B** (MLX, ~400 MB) — faster, lighter; intended for future streaming mode
  - **Whisper large-v3** (WhisperKit, ~3 GB) — fallback when the Metal Toolchain (required by MLX) isn't installed
- Optional LLM post-processing layer fixes misrecognitions conservatively (e.g. 配森→Python, 杰森→JSON). OpenAI-compatible API.
- Frameless capsule HUD with real-time RMS-driven 5-bar waveform.
- Pasteboard + Cmd+V injection with CJK IME detection and temporary switch to ASCII.
- Menu-bar only (LSUIElement, no Dock icon).

## Requirements

- macOS 15+
- Apple Silicon (arm64)
- Xcode / Swift 6.0+
- First-run downloads the selected ASR model to `~/Library/Application Support/VoiceTyping/models/<backend>/`. Switching backends keeps the old files cached — delete explicitly via **Manage Models…**.

## Build

```
make setup-metal  # ONE TIME: install Apple's Metal Toolchain (needed for Qwen MLX backends).
                  # If this fails with "DVTPlugInLoading" errors, run
                  # `sudo xcodebuild -runFirstLaunch` first, then retry.
make build        # builds signed .app bundle into ./build/VoiceTyping.app
                  # compiles MLX shaders → mlx.metallib → embedded in Contents/MacOS/
make run          # build + launch
make install      # copies to /Applications
make clean
```

On first launch, grant **Microphone** and **Accessibility** permissions when prompted. The default ASR model downloads in the background; progress shown in the menu bar. You can switch models anytime via the menu — cached models don't re-download.

If you skip `make setup-metal`, the app still boots but defaults to Whisper large-v3; Qwen options show "MLX shaders missing" until you install the toolchain and rebuild.

## Architecture

The ASR backend is behind a `SpeechRecognizer` protocol with per-backend subdirectories under `models/`. Current implementations are `WhisperKitRecognizer` and `QwenASRRecognizer` (wrapping `soniqo/speech-swift`). Adding a new backend means implementing the protocol and adding a case to `ASRBackend` — no other wiring changes.

## Documentation

详细文档在 [`docs/`](docs/) 目录下：

- [`docs/architecture.md`](docs/architecture.md) — 技术架构、模块设计、信息流
- [`docs/devlog/`](docs/devlog/) — 每个版本实现的功能、遇到的问题、修复方案
- [`docs/todo/`](docs/todo/) — 每个版本的 todo list 和 backlog
