import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// 2.3 SPEC (d) / lane U1: Dock + ⌘Tab for the resident app, the status item kept only as the polish alert, and the
/// Dock click. No real status item, Dock or activation-policy change: decisions and fakes only.
@MainActor
final class VoiceBarAppPresenceTests: XCTestCase {
    private final class FakePopover: MenuBarPopoverPresenting {
        var isShown = false
        var window: NSWindow?
        var onClose: ((MenuBarPopoverCloseCause) -> Void)?

        func show(relativeTo _: NSButton) {
            isShown = true
        }

        func close() {
            guard isShown else { return }
            isShown = false
            onClose?(.other)
        }
    }

    func testResidentAppIsRegularAndAnIsolatedInstanceStaysAnAccessory() {
        XCTAssertEqual(VoiceBarAppPresence.activationPolicy(enforcesSingletonInstance: true), .regular)
        XCTAssertEqual(VoiceBarAppPresence.activationPolicy(enforcesSingletonInstance: false), .accessory)
        XCTAssertTrue(VoiceBarAppPresence.statusItemIsAlertOnly(.regular))
        XCTAssertFalse(VoiceBarAppPresence.statusItemIsAlertOnly(.accessory))
    }

    func testDockClickPlan() {
        XCTAssertEqual(VoiceBarAppPresence.dockReopenPlan(policy: .regular, isSnoozed: true),
                       .init(unsnooze: true, settingsTab: .general))
        XCTAssertEqual(VoiceBarAppPresence.dockReopenPlan(policy: .regular, isSnoozed: false),
                       .init(unsnooze: false, settingsTab: .general))
        XCTAssertEqual(VoiceBarAppPresence.dockReopenPlan(policy: .accessory, isSnoozed: true), .none)
    }

    /// The popover acknowledges the alert as it opens; the item must stay until that popover closes.
    func testAlertOnlyItemOutlivesTheAlertWhileItsPopoverIsOpen() {
        let popover = FakePopover()
        let button = NSButton()
        let item = MenuBarStatusItemController(button: button, presenter: popover, isMouseEvent: { false })
        var applied: [Bool] = []
        item.onVisibilityChange = { applied.append($0) }
        item.alertOnly = true
        XCTAssertFalse(item.isItemVisible, "no alert, no menu-bar item")
        item.setAlert(true)
        XCTAssertTrue(item.isItemVisible)
        _ = button.accessibilityPerformPress()
        item.setAlert(false)
        XCTAssertTrue(item.isItemVisible, "the open popover keeps its anchor")
        popover.close()
        XCTAssertFalse(item.isItemVisible)
        XCTAssertEqual(applied.last, false)
    }

    func testAccessoryInstanceKeepsTheStatusItem() {
        let item = MenuBarStatusItemController(button: NSButton(), presenter: FakePopover())
        XCTAssertTrue(item.isItemVisible)
        item.setAlert(false)
        XCTAssertTrue(item.isItemVisible)
    }

    func testDockClickOnTheRegularAppOpensSettingsAtGeneral() throws {
        let app = AppDelegate()
        app.appliedActivationPolicy = .regular
        defer { app.settingsWindowForTesting?.close() }
        let allowDefault = (app as NSApplicationDelegate).applicationShouldHandleReopen?(
            NSApplication.shared, hasVisibleWindows: false
        ) ?? true
        XCTAssertFalse(allowDefault, "AppKit's default reopen would surface the SwiftUI placeholder")
        XCTAssertEqual(app.settingsTabRequestForTesting?.tab, .general)
        XCTAssertTrue(try XCTUnwrap(app.settingsWindowForTesting).isVisible)
    }

    func testDockMenuExistsOnlyWithADockIcon() {
        let app = AppDelegate()
        XCTAssertNil((app as NSApplicationDelegate).applicationDockMenu?(NSApplication.shared))
        app.appliedActivationPolicy = .regular
        let menu = (app as NSApplicationDelegate).applicationDockMenu?(NSApplication.shared)
        XCTAssertEqual(menu?.items.last?.title, "Hide notch for 1 hour")
    }

    func testAppMenuCarriesVersionHideNotchAndHide() throws {
        let menu = VoiceBarMainMenu.make(appDelegate: AppDelegate())
        let app = try XCTUnwrap(menu.items.first?.submenu)
        let version = try XCTUnwrap(app.item(withTitle: VoiceBarMainMenu.versionTitle()))
        XCTAssertFalse(version.isEnabled)
        XCTAssertEqual(app.item(withTitle: "Hide notch for 1 hour")?.action,
                       #selector(AppDelegate.hideNotchForOneHour(_:)))
        let hide = try XCTUnwrap(app.item(withTitle: "Hide VoiceBar"))
        XCTAssertEqual(hide.keyEquivalent, "h")
        XCTAssertEqual(hide.action, #selector(NSApplication.hide(_:)))
        XCTAssertEqual(app.item(withTitle: "Quit VoiceBar")?.keyEquivalent, "q")
        XCTAssertNotNil(menu.items.first { $0.submenu?.title == "Edit" }, "the Edit menu stays for text fields")
    }

    /// ⌘H on a regular app hides every window that can hide; the notch hides only through the snooze.
    func testHideVoiceBarLeavesTheNotchPanel() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertFalse(panel.canHide)
    }
}
