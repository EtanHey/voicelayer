import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Settings › General › Shortcut with the F5 listener off, and each restart result, light + dark. Skipped unless
/// VOICEBAR_F5_RESTART_SHOTS_DIR is set.
@MainActor
final class HotkeyListenerRestartShotsTests: XCTestCase {
    func testRenderRestartStates() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_F5_RESTART_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_F5_RESTART_SHOTS_DIR to render the F5 listener restart states")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, Bool, [HotkeyPermission], HotkeyListenerRestartOutcome?)] = [
            ("off", false, [.inputMonitoring], nil),
            ("restarted", true, [], .started),
            ("still-missing", false, [.inputMonitoring], .failed(missing: [.inputMonitoring])),
            ("refused-recording", false, [.accessibility], .refusedWhileRecording),
            ("on", true, [], nil),
        ]
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, enabled, missing, outcome) in states {
                let view = SettingsView(
                    hotkeyEnabled: enabled,
                    missingPermissions: missing,
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyRevision: { 0 },
                    initialTab: .general,
                    initialHotkeyListenerRestart: outcome
                )
                try render(
                    view.environment(\.colorScheme, scheme == "light" ? .light : .dark),
                    appearance: NSAppearance(named: appearance),
                    to: directory.appendingPathComponent("settings-f5-\(name)-\(scheme).png")
                )
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = CGSize(width: 780, height: 620)
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
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
