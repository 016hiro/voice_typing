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
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.9")
    ],
    targets: [
        .executableTarget(
            name: "VoiceTyping",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift")
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
        )
    ]
)
