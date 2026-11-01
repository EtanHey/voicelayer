import AppKit
import OffscreenTestSupport
import XCTest
@testable import VoiceBarUI

final class SettingsWindowBehaviorTests: XCTestCase {
    @MainActor
    func testSettingsUsesNormalWindowLevel() {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let window = NSWindow(contentRect: NSRect(x: -24000, y: -24000, width: 780, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.level = .floating
        SettingsWindowLifecycle.configureWindowBehavior(window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    func testNormalLevelFixKeepsActivationAndExplicitOrdering() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift")
        let source = try String(contentsOf: file)
        let start = try XCTUnwrap(source.range(of: "    func openSettingsWindow(tab:"))
        let end = try XCTUnwrap(source.range(of: "    func openSettingsFromMenuBar(", range: start.upperBound..<source.endIndex))
        let opener = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(opener.contains("SettingsWindowLifecycle.configureWindowBehavior(window)"))
        XCTAssertTrue(opener.contains("NSApp." + "activate(ignoringOtherApps: true)"))
        XCTAssertTrue(opener.contains("settingsWindow." + "makeKeyAndOrderFront(nil)\n            settingsWindow." + "orderFrontRegardless()"))
        XCTAssertTrue(opener.contains("window." + "makeKeyAndOrderFront(nil)\n        window." + "orderFrontRegardless()"))
    }
}
