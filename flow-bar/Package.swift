// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlowBar",
    platforms: [
        .macOS(.v14)   // Required for @Observable, spring(duration:bounce:), .symbolEffect
    ],
    targets: [
        .executableTarget(
            name: "FlowBar",
            path: "Sources/FlowBar"
        )
    ]
)
