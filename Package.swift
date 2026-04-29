// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "VoiceTyping", targets: ["VoiceTyping"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.9"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // v0.6.3: local MLX refiner stack — verified end-to-end via the
        // throwaway spike under Scripts/perf/refiner_spike/. mlx-swift-lm
        // is the official 2025+ home for MLXLLM/MLXLMCommon (separated
        // from mlx-swift-examples). swift-huggingface + swift-transformers
        // are the integration packages plugged in via MLXHuggingFace macros.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // Pin to WhisperKit's range (it requires <1.2.0). 1.1.6 already has
        // the `additionalContext:` chat-template overload we need for
        // `enable_thinking=False` (verified in source). Bump when WhisperKit
        // releases past v0.18.0 — main has dropped the swift-transformers
        // dep entirely, but no tag yet.
        .package(url: "https://github.com/huggingface/swift-transformers", "1.1.6"..<"1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceTyping",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/VoiceTyping",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "VoiceTypingTests",
            dependencies: [
                "VoiceTyping"
            ],
            path: "Tests/VoiceTypingTests"
        )
    ]
)
