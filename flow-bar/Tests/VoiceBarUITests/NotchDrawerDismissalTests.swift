import OffscreenTestSupport
import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A, Etan's History bugs: any click outside closes it (VoiceBar's own Settings window included), drag UP
/// closes it, and Esc closes it whichever app is focused (NATIVE-U4's missing receipt).
@MainActor
final class NotchDrawerDismissalTests: XCTestCase {
    private func panel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        VLOrderTestWindow(panel)
        return panel
    }

    private func settingsWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -19000, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: false)
        VLOrderTestWindow(window)
        return window
    }

    private func wired(_ model: NotchSurfaceModel, modal: Bool = false) -> NotchDrawerDismissal {
        let dismissal = NotchDrawerDismissal { model.send(.dismiss($0)) }
        dismissal.escapeIsOwnedElsewhere = { modal }
        return dismissal
    }

    func testShowRebindsAStalePanelBeforeTheFirstInsideClick() {
        let model = NotchSurfaceModel()
        let dismissal = wired(model)
        let oldPanel = panel(), livePanel = panel()
        defer { oldPanel.orderOut(nil); livePanel.orderOut(nil) }
        let hostWindow = HostWindowBox()
        hostWindow.rebind(oldPanel)
        hostWindow.bind(dismissal)
        model.send(.openSettings(.general))
        oldPanel.orderOut(nil) // Hide, then Show on the live host panel.
        model.send(.dismiss(.action))
        hostWindow.rebind(livePanel) // The production Show lifecycle call.
        VLOrderTestWindow(livePanel)
        model.send(.openSettings(.general))
        XCTAssertFalse(dismissal.handleLocalMouseDown(in: livePanel))
        XCTAssertEqual(model.drawer, .settings(.general), "first inside click must reach the drawer")
    }

    func testOutsideClickDiagnosticContainsOnlyWindowNumbersAndBooleans() {
        let model = NotchSurfaceModel()
        let dismissal = wired(model)
        let stored = panel(), live = panel(), outside = settingsWindow()
        defer { stored.orderOut(nil); live.orderOut(nil); outside.orderOut(nil) }
        dismissal.panelWindow = stored
        dismissal.livePanelWindow = { live }
        live.ignoresMouseEvents = true
        var lines: [String] = []
        dismissal.logOutsideClick = { lines.append($0) }
        model.send(.openHistory)
        XCTAssertFalse(dismissal.handleLocalMouseDown(in: live), "live panel wins over stale stored identity")
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(dismissal.handleLocalMouseDown(in: outside))
        XCTAssertEqual(lines, ["[VoiceBar] drawer_outside_click eventWindow=\(outside.windowNumber) storedPanelWindow=\(stored.windowNumber) livePanelWindow=\(live.windowNumber) panelKey=false ignoresMouseEvents=true"])
        dismissal.handleGlobalMouseDown(windowNumber: 42)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("eventWindow=42"))
    }

    func testMissingLivePanelIsNotReportedAsTheStaleStoredPanel() {
        let model = NotchSurfaceModel()
        let dismissal = wired(model)
        let stale = panel()
        defer { stale.orderOut(nil) }
        dismissal.panelWindow = stale
        dismissal.livePanelWindow = { nil }
        var lines: [String] = []
        dismissal.logOutsideClick = { lines.append($0) }
        model.send(.openHistory)
        XCTAssertTrue(dismissal.handleLocalMouseDown(in: stale))
        XCTAssertTrue(lines[0].contains("storedPanelWindow=\(stale.windowNumber) livePanelWindow=0"))
    }

    func testAClickOnVoiceBarsOwnSettingsWindowClosesHistory() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        let dismissal = wired(model)
        let panel = panel(), settings = settingsWindow()
        defer { panel.orderOut(nil); settings.orderOut(nil) }
        dismissal.panelWindow = panel

        XCTAssertFalse(dismissal.handleLocalMouseDown(in: panel), "a press on the drawn notch is inside")
        XCTAssertEqual(model.drawer, .history(.collapsed))
        XCTAssertTrue(dismissal.handleLocalMouseDown(in: settings), "VoiceBar's Settings window is outside")
        XCTAssertNil(model.drawer)
        XCTAssertEqual(model.journal.last?.event, .dismiss(.outsideClick))
    }

    func testAClickOnAnyOtherVoiceBarPanelOrNoWindowClosesIt() {
        let model = NotchSurfaceModel()
        let dismissal = wired(model)
        let notch = panel(), popover = panel()
        defer { notch.orderOut(nil); popover.orderOut(nil) }
        dismissal.panelWindow = notch
        model.send(.openSettings(.general))
        XCTAssertTrue(dismissal.handleLocalMouseDown(in: popover), "the menu-bar popover is another panel: outside")
        XCTAssertNil(model.drawer)
        model.send(.openHistory)
        XCTAssertTrue(dismissal.handleLocalMouseDown(in: nil))
        XCTAssertNil(model.drawer)
    }

    func testAClickInAnotherAppClosesIt() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        wired(model).handleGlobalMouseDown()
        XCTAssertNil(model.drawer)
    }

    /// NATIVE-U4 root cause: Esc reaching VoiceBar carries the key window (Settings) or none, never the
    /// non-activating notch panel, so 2.3's `event.window === panel` guard never let it close History.
    func testEscapeDeliveredToVoiceBarClosesTheDrawerWhicheverWindowIsKey() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        let dismissal = wired(model)
        XCTAssertTrue(dismissal.handleLocalKeyDown(keyCode: NotchDrawerDismissal.escapeKeyCode), "consumed")
        XCTAssertNil(model.drawer)
        XCTAssertEqual(model.journal.last?.event, .dismiss(.escape), "the Esc receipt")
    }

    func testEscapeFromAnotherFocusedAppClosesIt() {
        let model = NotchSurfaceModel()
        model.send(.openSettings(.speech))
        wired(model).handleGlobalKeyDown(keyCode: NotchDrawerDismissal.escapeKeyCode)
        XCTAssertNil(model.drawer)
    }

    func testEscapeOwnedByASheetOrCompositionIsLeftAlone() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        let dismissal = wired(model, modal: true)
        XCTAssertFalse(dismissal.handleLocalKeyDown(keyCode: NotchDrawerDismissal.escapeKeyCode))
        XCTAssertEqual(model.drawer, .history(.collapsed))
    }

    func testOtherKeysNeverDismiss() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        let dismissal = wired(model)
        XCTAssertFalse(dismissal.handleLocalKeyDown(keyCode: 0))
        dismissal.handleGlobalKeyDown(keyCode: 36)
        XCTAssertEqual(model.drawer, .history(.collapsed))
    }

    func testMonitorsInstallOnceAndRemoveCleanly() {
        let dismissal = NotchDrawerDismissal { _ in }
        XCTAssertFalse(dismissal.isMonitoring)
        dismissal.start()
        XCTAssertTrue(dismissal.isMonitoring)
        dismissal.start()
        XCTAssertTrue(dismissal.isMonitoring)
        dismissal.stop()
        XCTAssertFalse(dismissal.isMonitoring)
    }

    // MARK: Modal observer

    func testTheModalObserverReportsSheetsToTheMachine() {
        let model = NotchSurfaceModel()
        model.send(.openHistory)
        var modal = false
        let observer = NotchModalObserver(isModalProvider: { modal }) { model.send(.modalChanged($0)) }
        observer.refresh()
        XCTAssertEqual(model.drawer, .history(.collapsed))
        modal = true
        observer.refresh()
        XCTAssertNil(model.drawer, "a sheet beginning closes the drawer")
        XCTAssertEqual(model.send(.openHistory), .refused(.modal))
        modal = false
        observer.refresh()
        XCTAssertEqual(model.send(.openHistory), .changed(from: .closed, to: .history(.collapsed)))
    }

    // MARK: Drag

    /// Drag UP mirrors drag-down: a press on the open drawer's body pushed upward settles closed.
    func testADragUpFromTheOpenDrawerSettlesClosed() {
        var pull = NotchHistoryPull()
        let range: CGFloat = 302
        pull.press(y: 200, progress: 1, time: 0)
        var shown: CGFloat = 1
        for (index, y) in stride(from: 196, through: 40, by: -12).enumerated() {
            shown = pull.move(y: CGFloat(y), time: Double(index + 1) * 0.016, range: range, seed: 1) ?? shown
        }
        XCTAssertLessThan(shown, 0.6)
        guard case let .settle(open, velocity) = pull.release(progress: shown) else {
            return XCTFail("a drag ends in a settle")
        }
        XCTAssertFalse(open, "pushed up: closed")
        XCTAssertLessThan(velocity, 0)
    }

    func testPullingPastOpenArmsSettings() {
        var pull = NotchHistoryPull()
        let range: CGFloat = 302
        pull.press(y: 20, progress: 1, time: 0)
        _ = pull.move(y: 30, time: 0.02, range: range, seed: 1)
        XCTAssertLessThan(pull.rawProgress, NotchHistoryMorph.settingsPullThreshold)
        let shown = pull.move(y: 30 + range * 0.35, time: 0.3, range: range) ?? 0
        XCTAssertGreaterThanOrEqual(pull.rawProgress, NotchHistoryMorph.settingsPullThreshold)
        XCTAssertLessThan(shown, 1.1, "the drawn panel only stretches a little (rubber band)")
        guard case let .settle(open, _) = pull.release(progress: shown) else { return XCTFail() }
        XCTAssertTrue(open)
        XCTAssertEqual(pull.rawProgress, 0, "released: nothing stays armed")
    }

    func testTheHandleSettlesOnSixOrEight() {
        XCTAssertEqual(NotchHistoryMorph.visibleRows, 6)
        XCTAssertEqual(NotchHistoryMorph.maximumRows, 8)
        XCTAssertEqual(NotchHistoryMorph.maximumEntries, 20)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(6.9, maximum: 8), 6)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(7.0, maximum: 8), 8)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(9.4, maximum: 8), 8)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(8, maximum: 7), 7, "never an empty row past the last one")
        XCTAssertEqual(NotchHistoryDetent.expanded.rows(entryCount: 20), 8)
        XCTAssertEqual(NotchHistoryDetent.expanded.rows(entryCount: 3), 6)
        XCTAssertEqual(NotchHistoryDetent.collapsed.rows(entryCount: 20), 6)
    }

    func testOneSpringNoStages() {
        XCTAssertEqual(NotchHistoryMorph.openResponse, NotchHistoryMorph.closeResponse)
        XCTAssertEqual(NotchHistoryMorph.openDampingFraction, NotchHistoryMorph.closeDampingFraction)
        XCTAssertEqual(NotchHistoryMorph.pullResponse, NotchHistoryMorph.springResponse)
        for p in stride(from: CGFloat(0), through: 1, by: 0.1) {
            XCTAssertEqual(NotchHistoryMorph.rowsOpacity(progress: p), p, accuracy: 1e-9, "opacity follows p from 0")
            XCTAssertEqual(NotchHistoryMorph.rowsBlur(progress: p), 0)
            XCTAssertEqual(NotchHistoryMorph.rowsScale(progress: p), 1)
        }
    }
}
