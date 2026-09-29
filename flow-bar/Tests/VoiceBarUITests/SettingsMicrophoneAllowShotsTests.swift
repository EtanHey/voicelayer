import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Settings › General with the Microphone row never asked, denied and granted, light + dark. Skipped unless
/// VOICEBAR_MIC_ALLOW_SHOTS_DIR is set.
@MainActor
final class SettingsMicrophoneAllowShotsTests: XCTestCase {
    func testRenderMicrophonePermissionRowStates() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_MIC_ALLOW_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_MIC_ALLOW_SHOTS_DIR to render the Settings microphone row")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, SetupMicrophoneAuthorization)] = [
            ("not-requested", .notRequested), ("denied", .denied), ("granted", .granted),
        ]
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, status) in states {
                let view = SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyRevision: { 0 },
                    microphoneAuthorization: { status },
                    initialTab: .general
                )
                try render(
                    view.environment(\.colorScheme, scheme == "light" ? .light : .dark),
                    appearance: NSAppearance(named: appearance),
                    to: directory.appendingPathComponent("settings-mic-\(name)-\(scheme).png")
                )
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = CGSize(width: 780, height: 900)
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
            throw NSError(domain: "SettingsMicrophoneAllowShots", code: 1)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SettingsMicrophoneAllowShots", code: 2)
        }
        try png.write(to: url, options: .atomic)
    }
}
