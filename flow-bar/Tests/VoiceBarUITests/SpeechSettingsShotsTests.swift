import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Synthetic daemon fixtures rendered through the production Settings shell; no live audio or app swap.
@MainActor
final class SpeechSettingsShotsTests: XCTestCase {
    func testRenderSpeechTab() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SPEECH_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_SPEECH_SHOTS_DIR to render Speech settings")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["fast", "clone-down-locked", "not-measured", "clone-running"] {
            let locked = name == "clone-down-locked"
            var raw = SpeechSettingsTests.controls(rateSource: locked ? "environment" : "settings")
            var profiles = raw["profiles"] as! [String: [String: Any]]
            for kind in SpeechProfile.allCases {
                profiles[kind.rawValue]?["last_first_audio_ms"] = kind == .short ? 420 : 1300
                profiles[kind.rawValue]?["last_first_audio"] = ["engine": "edge-tts", "origin": kind == .short ? "speak" : "preview", "fallback": locked]
                if locked || (name == "clone-running" && kind == .long) {
                    profiles[kind.rawValue]?["engine"] = ["source": locked ? "environment" : "settings", "raw": "clone", "effective": "clone"]
                    profiles[kind.rawValue]?["voice"] = ["source": locked ? "environment" : "settings", "raw": "theo-c4", "effective": "theo-c4"]
                }
                if name == "not-measured" {
                    profiles[kind.rawValue]?["last_first_audio_ms"] = NSNull()
                    profiles[kind.rawValue]?["last_first_audio"] = NSNull()
                }
            }
            if name == "clone-running" {
                raw["clone_daemon"] = "up"
                profiles["long"]?["last_first_audio_ms"] = 2100
                profiles["long"]?["last_first_audio"] = ["engine": "qwen3-tts", "origin": "preview", "fallback": false]
            }
            raw["profiles"] = profiles
            let controls = try XCTUnwrap(SpeechControlsState(controls: raw))
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = SettingsView(
                    hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                    modelsStatus: { ModelsSettingsState(healthEvent: ["type": "health", "recording_state": "idle",
                        "model_status": ["residency": "not_loaded", "configured_effort": "accurate",
                                         "configured_model": ["installed": true]]]) },
                    onRefreshModelsStatus: {}, speechControls: { controls }, speechConnected: { true },
                    speechBusyReason: { name == "clone-running" ? "Speaking…" : nil },
                    onChangeSpeech: { _, _ in }, onSelectSpeechEngine: { _, _, _ in }, onPreviewSpeech: { _ in }, vocabularyRevision: { 0 },
                    footerPresentation: { .resolve(isConnected: true, mode: .idle, captureLive: false,
                                                  errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true) },
                    initialTab: .speech
                )
                try render(view.environment(\.colorScheme, scheme == "light" ? .light : .dark),
                           appearance: NSAppearance(named: appearance),
                           to: directory.appendingPathComponent("speech-\(name)-\(scheme).png"))
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = CGSize(width: 780, height: 1000)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw NSError(domain: "SpeechSettingsShots", code: 1)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SpeechSettingsShots", code: 2)
        }
        try png.write(to: url, options: .atomic)
    }
}
