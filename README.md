# VoiceTyping

A macOS menu-bar voice input app. Hold **Fn** to dictate, release to paste the transcribed text into the focused input field.

- Default language: Simplified Chinese (zh-CN). Also supports English, Traditional Chinese, Japanese, Korean.
- Local speech recognition using WhisperKit (`openai_whisper-large-v3`) on Apple Silicon.
- Optional LLM post-processing layer fixes misrecognitions conservatively (e.g. 配森→Python, 杰森→JSON). OpenAI-compatible API.
- Frameless capsule HUD with real-time RMS-driven 5-bar waveform.
- Pasteboard + Cmd+V injection with CJK IME detection and temporary switch to ASCII.
- Menu-bar only (LSUIElement, no Dock icon).

## Requirements

- macOS 14+
- Apple Silicon (arm64)
- Xcode / Swift 5.9+
- First-run downloads the Whisper large-v3 model (~3 GB CoreML format) to `~/Library/Application Support/VoiceTyping/models/`

## Build

```
make build     # builds signed .app bundle into ./build/VoiceTyping.app
make run       # build + launch
make install   # copies to /Applications
make clean
```

On first launch, grant **Microphone** and **Accessibility** permissions when prompted.

## Architecture

The ASR backend is behind a `SpeechRecognizer` protocol so future versions can swap to different Whisper builds, whisper.cpp, Apple Speech, or a cloud API without touching the rest of the app.

## Documentation

详细文档在 [`docs/`](docs/) 目录下：

- [`docs/architecture.md`](docs/architecture.md) — 技术架构、模块设计、信息流
- [`docs/devlog/`](docs/devlog/) — 每个版本实现的功能、遇到的问题、修复方案
- [`docs/todo/`](docs/todo/) — 每个版本的 todo list 和 backlog
