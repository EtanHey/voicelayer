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
            dependencies: ["VoiceBarUI", "HotkeyAtomics", "StallSampler"],
            path: "Sources/VoiceBar",
            // Dev/CI-only QA probes (Etan ruling 2). A release build gets them only through
            // `VOICEBAR_QA_BUILD=1 bash flow-bar/build-app.sh` (-Xswiftc -DVOICEBAR_QA).
            swiftSettings: [.define("VOICEBAR_QA", .when(configuration: .debug))]
        ),
        .target(name: "HotkeyAtomics", path: "Sources/HotkeyAtomics", publicHeadersPath: "include"),
        // c8 X: the stall watchdog's frame walk. C on purpose: nothing may allocate or lock while the
        // sampled thread is stopped, and Swift cannot promise that.
        .target(name: "StallSampler", path: "Sources/StallSampler", publicHeadersPath: "include"),
        .target(
            name: "VoiceBarUI",
            path: "Sources/VoiceBarUI"
        ),
        .executableTarget(
            name: "NotchCaptureContrastVerifier",
            dependencies: ["VoiceBarUI"],
            path: "Sources/NotchCaptureContrastVerifier"
        ),
        .executableTarget(
            name: "NotchGlassBackdropFixture",
            path: "Sources/NotchGlassBackdropFixture"
        ),
        .target(
            name: "OffscreenTestSupport",
            path: "Tests/OffscreenTestSupport",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "VoiceBarTests",
            dependencies: ["VoiceBar", "VoiceBarUI", "OffscreenTestSupport", "StallSampler"],
            path: "Tests/VoiceBarTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "VoiceBarUITests",
            dependencies: ["VoiceBarUI", "OffscreenTestSupport"],
            path: "Tests/VoiceBarUITests",
            exclude: ["Snapshots"]
        ),
    ]
)
