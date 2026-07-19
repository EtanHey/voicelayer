// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceBar",
    platforms: [
        .macOS(.v14), // Required for @Observable, spring(duration:bounce:), .symbolEffect
    ],
    targets: [
        .executableTarget(
            name: "VoiceBar",
            dependencies: ["VoiceBarUI"],
            path: "Sources/VoiceBar"
        ),
        .target(
            name: "VoiceBarUI",
            path: "Sources/VoiceBarUI"
        ),
        .executableTarget(
            name: "NotchCaptureContrastVerifier",
            dependencies: ["VoiceBarUI"],
            path: "Sources/NotchCaptureContrastVerifier"
        ),
        .testTarget(
            name: "VoiceBarTests",
            dependencies: ["VoiceBar", "VoiceBarUI"],
            path: "Tests/VoiceBarTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "VoiceBarUITests",
            dependencies: ["VoiceBarUI"],
            path: "Tests/VoiceBarUITests"
        ),
    ]
)
