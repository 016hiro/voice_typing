// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceTyping", targets: ["VoiceTyping"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceTyping",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
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
