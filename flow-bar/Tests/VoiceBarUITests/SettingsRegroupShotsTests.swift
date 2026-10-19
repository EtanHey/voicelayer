import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Production Settings views with synthetic health; never replaces the resident app or opens audio.
@MainActor
final class SettingsRegroupShotsTests: XCTestCase {
    func testRenderRegroupedSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SETTINGS_REGROUP_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_SETTINGS_REGROUP_SHOTS_DIR to render regrouped settings")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": "idle",
            "model_status": [
                "residency": "loaded", "configured_effort": "accurate",
                "configured_model": ["name": "large-v3-turbo", "size_mb": 1600, "installed": true],
            ],
            "polish_controls": [
                "model_polish": ["source": "default", "raw": NSNull(), "effective": "off"],
                "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            ],
        ])
        for tab in [SettingsTab.general, .transcription] {
            for (name, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", .dark, .darkAqua),
            ] {
                let view = SettingsView(
                    hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                    modelsStatus: { state }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 },
                    footerPresentation: { .resolve(isConnected: true, mode: .idle, captureLive: false,
                                                  errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true) },
                    initialTab: tab
                )
                try render(view.environment(\.colorScheme, scheme), appearance: NSAppearance(named: appearance),
                           to: directory.appendingPathComponent("\(tab.title.lowercased())-\(name).png"))
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = CGSize(width: 780, height: 620)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
