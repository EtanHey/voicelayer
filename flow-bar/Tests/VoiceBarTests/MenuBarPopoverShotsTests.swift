import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// UXP-4 parity: the popover's content as the status item now hosts it (`MenuBarPopoverHost`), light + dark.
/// Skipped unless VOICEBAR_UXP4_SHOTS_DIR is set.
@MainActor
final class MenuBarPopoverShotsTests: XCTestCase {
    func testRenderMenuBarPopover() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_UXP4_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_UXP4_SHOTS_DIR to render the menu-bar popover")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppDelegate()
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: MenuBarPopoverHost(appDelegate: app)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme == "light" ? .light : .dark))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("popover-\(scheme).png"), options: .atomic)
            window.orderOut(nil)
        }
    }
}
