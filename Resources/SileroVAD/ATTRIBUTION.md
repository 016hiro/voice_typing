# Silero VAD bundled weights

## Source

- **Upstream model**: [snakers4/silero-vad](https://github.com/snakers4/silero-vad) v5
- **MLX conversion**: [aufklarer/Silero-VAD-v5-MLX](https://huggingface.co/aufklarer/Silero-VAD-v5-MLX)
- **Files bundled**: `model.safetensors` (~1.2 MB), `config.json`

## License

Silero VAD is licensed under the **MIT License**. See https://github.com/snakers4/silero-vad/blob/master/LICENSE for the full text.

## Why bundled

`SileroVADModel.fromPretrained()` otherwise downloads the weights from HuggingFace on first use — a ~1 MB network fetch triggered the first time the user enables streaming transcription. Offline users (no network, captive portal, etc.) would hang indefinitely on that first Fn press. Shipping the weights inside the app bundle makes streaming work offline from install.

Loaded at runtime via `QwenASRRecognizer.bundledVADCacheDir()` with `offlineMode: true`.
