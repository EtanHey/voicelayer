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
            path: "Sources/VoiceBar"
        ),
    ]
)
