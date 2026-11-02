import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Settings › General › Version in each status, light + dark, tall enough that the bottom section is in frame.
/// Skipped unless VOICEBAR_VERSION_SHOTS_DIR is set. The cask fetch is a fixture; nothing touches the network.
@MainActor
final class SettingsVersionShotsTests: XCTestCase {
    nonisolated private static func cask(_ version: String) -> String {
        "cask \"voicebar\" do\n  version \"\(version)\"\nend\n"
    }

    func testRenderVersionStatuses() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_VERSION_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_VERSION_SHOTS_DIR to render the Settings version row")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let installed = VoiceBarInstalledVersion(version: "2.2.59", commit: "1234567890abcdef1234567890abcdef12345678")
        let states: [(String, VoiceBarVersionCheck.Fetch)] = [
            ("ahead", { Self.cask("2.2.58") }),
            ("latest", { Self.cask("2.2.59") }),
            ("available", { Self.cask("2.2.60") }),
            ("could-not-check", { throw URLError(.notConnectedToInternet) }),
        ]
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, fetch) in states {
                let view = SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyRevision: { 0 },
                    initialTab: .general,
                    installedVersion: installed,
                    versionCheck: VoiceBarVersionCheck(fetch: fetch)
                )
                try render(
                    view.environment(\.colorScheme, scheme == "light" ? .light : .dark),
                    appearance: NSAppearance(named: appearance),
                    to: directory.appendingPathComponent("settings-version-\(name)-\(scheme).png")
                )
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = CGSize(width: 780, height: 1700)
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw NSError(domain: "SettingsVersionShots", code: 1)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SettingsVersionShots", code: 2)
        }
        try png.write(to: url, options: .atomic)
    }
}
