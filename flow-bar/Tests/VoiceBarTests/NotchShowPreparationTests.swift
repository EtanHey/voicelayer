import AppKit
import OffscreenTestSupport
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchShowPreparationTests: XCTestCase {
    func testProductShowRebindsBothTheHostBoxAndDismissalBeforeTheFirstInsideClick() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.voiceState.sendCommand = { _ in }
        app.voiceState.setConnectionStatus(true)
        let old = FloatingPillPanel(content: NSView())
        let live = FloatingPillPanel(content: NSView())
        defer { app.unsnoozeNow(); old.orderOut(nil); live.orderOut(nil) }
        app.configurePanelVisibilityForTesting(old)
        let surface = app.notchSurfaceForTesting
        let dismissal = NotchDrawerDismissal { surface.send(.dismiss($0)) }
        let host = app.notchHostWindowForTesting
        host.rebind(old)
        host.bind(dismissal)
        surface.send(.openSettings(.general))
        app.hideNotchForOneHour(nil)
        XCTAssertNil(surface.drawer)
        XCTAssertEqual(surface.journal.last?.event, .dismiss(.hidden))
        XCTAssertEqual(surface.hideGeneration, 1)
        app.configurePanelVisibilityForTesting(live)
        app.unsnoozeNow()
        XCTAssertTrue(host.window === live)
        XCTAssertTrue(dismissal.panelWindow === live)
        surface.send(.openSettings(.general))
        XCTAssertFalse(dismissal.handleLocalMouseDown(in: live))
        XCTAssertEqual(surface.drawer, .settings(.general))
        // A delayed report from the old hosting view cannot replace the app's live panel.
        host.rebind(nil)
        XCTAssertTrue(host.window === live)
        XCTAssertTrue(dismissal.panelWindow === live)
    }
}
