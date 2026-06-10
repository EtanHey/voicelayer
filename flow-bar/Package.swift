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
        // Isolated v9 geometry preview window — NO socket, NO daemon, cannot collide
        // with the resident VoiceBar. Renders NotchV9PreviewSurface for native glass
        // screenshots (the qa-video gate's real-glass capture).
        .executableTarget(
            name: "VoiceBarV9Preview",
            dependencies: ["VoiceBarUI"],
            path: "Sources/VoiceBarV9Preview"
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
