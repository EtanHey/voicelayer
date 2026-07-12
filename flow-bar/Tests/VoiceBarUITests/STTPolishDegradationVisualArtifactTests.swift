import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class STTPolishDegradationVisualArtifactTests: XCTestCase {
    func testWritesDegradedAudioSettingsArtifact() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-07-12-stt-polish-loud-degradation")
            .appendingPathComponent("after")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: {
                [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
            },
            selectedDeviceID: { "built-in" },
            onSelectDevice: { _ in },
            polishDegradation: {
                STTPolishDegradation(
                    reason: "missing-binary",
                    hint: "STT polish unavailable — install mlx-lm (`uv tool install mlx-lm` or `pip install mlx-lm`)"
                )
            },
            onDismissPolishDegradation: {},
            initialTab: .audio
        )
        .frame(width: 520, height: 620)

        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not create bitmap for degraded Audio settings")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode degraded Audio settings PNG")
        }
        try png.write(to: outputDirectory.appendingPathComponent("settings-audio-degraded.png"))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
