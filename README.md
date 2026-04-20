# VoiceTyping

A macOS menu-bar voice input app. Hold **Fn** to dictate, release to paste the transcribed text into the focused input field.

- Default language: Simplified Chinese (zh-CN). Also supports English, Traditional Chinese, Japanese, Korean.
- Swappable local ASR backend (select from the menu):
  - **Qwen3-ASR 1.7B** (MLX, ~1.4 GB) — SOTA open-source ASR, beats Whisper-large-v3 on multilingual benchmarks. Default when MLX is available.
  - **Qwen3-ASR 0.6B** (MLX, ~400 MB) — faster, lighter; pairs well with the experimental streaming toggle below
  - **Whisper large-v3** (WhisperKit, ~3 GB) — fallback when the Metal Toolchain (required by MLX) isn't installed
- Four-level LLM refinement (OpenAI-compatible API): `off` / `conservative` (default, fix misrecognitions only) / `light` (also removes fillers & stutters) / `aggressive` (also formats lists & lightly polishes wording). Fails soft — never loses text.
- **Custom dictionary** with dual-layer injection: term-only entries anchor ASR spelling (Qwen context + Whisper prompt), `term + pronunciations` entries also produce rewrite rules in the LLM glossary. LRU-ranked, token-budgeted, persisted to JSON.
- Optional **Raw-first inject** mode: pastes raw ASR instantly, then replaces with refined text once the LLM returns (only if the user hasn't moved on). Trades a visible flicker for lower perceived latency.
- Optional **Streaming transcription** (experimental, Qwen3 only): VAD-segmented ASR so the capsule reveals transcript progressively and long recordings can be transcribed past the per-segment token cap. Injection still happens once at the end — the streaming shows in the HUD, not in the focused textfield. First use downloads Silero VAD (~2 MB).
- Transparent A10 Morse-rhythm HUD — seven staggered bars pulsing beside a monospace label ("Listening" / "Transcribing" / "Refining"), dual-halo shadow so it reads over any background.
- Original app icon family — 10 macOS-style designs generated from `Scripts/generate_icons.swift`; swap the active design with `make icons ICON=NN && make build`.
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
make setup-cert   # ONE TIME: create a local self-signed codesigning identity so
                  # rebuilds keep the same cdhash — macOS TCC grants (Microphone,
                  # Accessibility) then persist instead of being reset each build.
                  # Safe to skip; without it `make build` falls back to ad-hoc sign.
make build        # builds signed .app bundle into ./build/VoiceTyping.app
                  # compiles MLX shaders → mlx.metallib → embedded in Contents/MacOS/
make run          # build + launch
make install      # copies to /Applications
make clean
make reset-perms  # dev: tccutil reset Microphone + Accessibility for this bundle
make test         # unit tests only (fast, no fixtures / models needed). Runs in CI.
make test-e2e     # full regression: unit + ASR on audio fixtures. Requires MLX
                  # metallib + Qwen model downloaded. See Tests/Fixtures/README.md
                  # for how to add fixtures (self-record or public corpora).
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
