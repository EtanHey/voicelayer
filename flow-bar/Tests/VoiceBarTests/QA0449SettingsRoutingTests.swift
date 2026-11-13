import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

@MainActor
final class QA0449SettingsRoutingTests: XCTestCase {
    func testVisibleNotchKeepsSystemAndMenuSettingsRequestsInTheDrawer() throws {
        let app = AppDelegate()
        let panel = FloatingPillPanel(content: NSHostingView(rootView: Color.black.frame(width: 300, height: 32)))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        app.configurePanelVisibilityForTesting(panel)
        VLOrderTestWindow(panel)
        for tab in SettingsTab.allCases {
            app.openSettingsWindow(tab: tab)
            XCTAssertEqual(app.notchSurfaceForTesting.drawer, .settings(tab))
            XCTAssertNil(app.settingsWindowForTesting)
        }
        app.openSettingsWindow(tab: .general, focus: .microphonePriority)
        XCTAssertEqual(app.notchSurfaceForTesting.settingsRequest?.focus, .microphonePriority)
        app.openSettingsWindow(tab: .dictionary)
        for selector in ["showSettingsWindow:", "showSettings:", "showPreferencesWindow:", "orderFrontPreferencesPanel:"] {
            app.perform(NSSelectorFromString(selector), with: nil)
            XCTAssertEqual(app.notchSurfaceForTesting.drawer, .settings(.dictionary))
            XCTAssertNil(app.settingsWindowForTesting)
        }
        let main = VoiceBarMainMenu.make(appDelegate: app)
        let settings = try XCTUnwrap(main.items.first?.submenu?.item(withTitle: "Settings…"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertNil(app.settingsWindowForTesting, "Cmd+, uses the same drawer route")
        app.configurePillContextMenuForTesting()
        let menu = app.pillContextMenuControllerForTesting.makeNotchMenu()
        let item = try XCTUnwrap(menu.item(withTitle: "Settings…"))
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNil(app.settingsWindowForTesting)
    }
}
