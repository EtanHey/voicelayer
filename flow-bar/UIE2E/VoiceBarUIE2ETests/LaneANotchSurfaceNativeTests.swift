import AppKit
import XCTest

/// 2.4 Lane A, native only (pointer and key events): run on the M1 test rig through the lead, NEVER on the M4.
/// Not part of a voicebar-ui-e2e.sh scenario; run from that build's xctestrun with
/// -only-testing:VoiceBarUIE2ETests/LaneANotchSurfaceNativeTests. The QA host logs every notch-surface transition as
/// an events.json receipt ("notch surface history(collapsed) -> closed (dismiss escape)"), so each case proves the
/// exact cause that closed or opened a drawer, not just that a panel disappeared.
final class LaneANotchSurfaceNativeTests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    private let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    private var previousApp: NSRunningApplication?

    private var pill: XCUIElement { app.dialogs["VoiceBar QA Pill"] }
    private var handle: XCUIElement { pill.descendants(matching: .any)["notch-history-extend-handle"] }
    private var settingsTabs: XCUIElement { pill.descendants(matching: .any)["Settings tabs"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        root = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_ROOT"]))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".uie2e-sandbox")), "voicebar-ui-e2e-v1\n")
        let appURL = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_APP"]))
        guard Bundle(url: appURL)?.bundleIdentifier == "com.voicelayer.voicebar.uie2e",
              Bundle(url: appURL)?.object(forInfoDictionaryKey: "VoiceBarUIE2EOnly") as? Bool == true
        else { throw NSError(domain: "UIE2E unsafe app", code: 1) }
        guard Bundle(url: appURL)?.object(forInfoDictionaryKey: "UIE2EGate2245") as? Bool != true else {
            throw XCTSkip("Lane A native cases need a standard UIE2E build, not a GATE2245 one")
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        app = XCUIApplication(url: appURL)
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_SCENARIO": "full", "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "QA_VOICE_DISABLE_FLAG_PATH": root.appendingPathComponent("disabled").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.lane-a.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path,
            // 20 dictations: the list holds 20 and scrolls past the 6 / 8 visible rows.
            "VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS": "20"]
        app.launch()
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "the QA pill exists")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        previousApp?.activate()
    }

    // MARK: Helpers

    private func events() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("events.json")))) ?? []
    }

    /// Waits for a NEW surface receipt containing `fragment` after `before` events.
    private func waitForReceipt(_ fragment: String, after before: Int, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events().dropFirst(before).contains(where: { $0.contains(fragment) }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func attachEvents(_ name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: events(), options: [.prettyPrinted]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "LaneA-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func anchored(_ element: XCUIElement) throws -> XCUICoordinate {
        try XCTUnwrap(uie2eForegroundPoint(element, via: finder), "Finder anchor")
    }

    /// Opens History the way a user does: Finder frontmost, hover the notch, click History.
    private func openHistoryFromFinder() throws {
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        try anchored(pill).hover()
        let history = pill.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 4))
        let before = events().count
        try anchored(history).click()
        XCTAssertTrue(waitForReceipt("-> history(collapsed) (open history)", after: before), "History opened")
        XCTAssertTrue(handle.waitForExistence(timeout: 4))
        XCTAssertEqual(handle.value as? String, "6 of 8 rows", "collapsed 6")
    }

    /// Brings up the QA Settings window through a product path: the pill's right-click Settings… (0510 N1: the
    /// drawer itself never hands off to the window).
    private func showSettingsWindow() throws -> XCUIElement {
        let settings = app.windows["VoiceBar QA Settings"]
        try anchored(pill).rightClick()
        let item = app.menuItems["Settings…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(settings.waitForExistence(timeout: 4), "the QA Settings window is up")
        return settings
    }

    // MARK: Cases

    /// Etan: History closes on ANY click outside it, VoiceBar's own Settings window included.
    func testAClickOnVoiceBarsOwnSettingsWindowClosesHistory() throws {
        let settings = try showSettingsWindow()
        pill.hover()
        pill.buttons["History"].click()
        XCTAssertTrue(handle.waitForExistence(timeout: 4), "History is open with Settings on screen")
        let before = events().count
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForReceipt("-> closed (dismiss outsideClick)", after: before), "outside click closed History")
        XCTAssertTrue(handle.waitForNonExistence(timeout: 3))
        attachEvents("settings-window-click")
    }

    /// NATIVE-U4's stale case, now the product rule: Esc closes History even while VoiceBar's Settings is key.
    func testEscapeClosesHistoryWhileVoiceBarSettingsIsKey() throws {
        let settings = try showSettingsWindow()
        settings.click()
        pill.hover()
        pill.buttons["History"].click()
        XCTAssertTrue(handle.waitForExistence(timeout: 4))
        let before = events().count
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForReceipt("-> closed (dismiss escape)", after: before), "the Esc receipt")
        XCTAssertTrue(handle.waitForNonExistence(timeout: 3))
        attachEvents("escape-settings-key")
    }

    /// Esc with another app frontmost (the global monitor path).
    func testEscapeFromAnotherAppClosesHistory() throws {
        try openHistoryFromFinder()
        let before = events().count
        finder.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForReceipt("-> closed (dismiss escape)", after: before))
        XCTAssertEqual(finder.state, .runningForeground, "Finder stays frontmost")
        attachEvents("escape-finder")
    }

    /// Etan: drag UP closes it, mirroring drag-down to open. The press lands on a row.
    func testDraggingTheRowsUpClosesHistory() throws {
        try openHistoryFromFinder()
        let row = try anchored(pill).withOffset(CGVector(dx: 0, dy: 120))
        let before = events().count
        row.press(forDuration: 0.1, thenDragTo: row.withOffset(CGVector(dx: 0, dy: -200)))
        XCTAssertTrue(waitForReceipt("-> closed (dismiss dragUp)", after: before), "the drag-up receipt")
        XCTAssertTrue(handle.waitForNonExistence(timeout: 3))
        attachEvents("drag-up")
    }

    /// Etan: drag further down opens Settings in the notch.
    func testPullingHistoryFurtherDownOpensTheSettingsDrawer() throws {
        try openHistoryFromFinder()
        let rows = try anchored(pill).withOffset(CGVector(dx: 0, dy: 80))
        let before = events().count
        rows.press(forDuration: 0.1, thenDragTo: rows.withOffset(CGVector(dx: 0, dy: 160)))
        XCTAssertTrue(waitForReceipt("-> settings(general) (open settings general)", after: before))
        XCTAssertTrue(settingsTabs.waitForExistence(timeout: 3), "the drawer's tabs")
        attachEvents("pull-to-settings")
    }

    /// The gear opens Settings as a drawer; its tabs switch in place, each with real settings and no hand-off (0510 N1).
    func testTheGearOpensTheSettingsDrawerAndItsTabsSwitchInPlace() throws {
        finder.activate()
        try anchored(pill).hover()
        let gear = pill.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 4))
        var before = events().count
        try anchored(gear).click()
        XCTAssertTrue(waitForReceipt("-> settings(general) (open settings general)", after: before))
        XCTAssertTrue(settingsTabs.waitForExistence(timeout: 3))
        for title in ["General", "Transcription", "Dictionary", "Speech", "History"] {
            XCTAssertTrue(pill.buttons[title].exists, "\(title) tab")
        }
        before = events().count
        try anchored(pill.buttons["Transcription"]).click()
        XCTAssertTrue(waitForReceipt("(tab transcription)", after: before))
        XCTAssertTrue(settingsTabs.exists, "the drawer stays open on its new tab")
        XCTAssertFalse(pill.buttons["Open Transcription settings"].exists, "0510 N1: no hand-off to the window")
        XCTAssertFalse(pill.buttons["All settings…"].exists, "0510 N1: no hand-off to the window")
        attachEvents("gear-tab-in-place")
    }

    /// The list holds 20 and scrolls; the handle settles on 6 or 8, never between.
    func testTwentyRowsScrollAndTheHandleSettlesOnADetent() throws {
        try openHistoryFromFinder()
        let centre = try anchored(handle)
        centre.press(forDuration: 0.15, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: 1.2 * 46)))
        let deadline = Date().addingTimeInterval(3)
        while handle.value as? String != "8 of 8 rows", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(handle.value as? String, "8 of 8 rows", "past the midpoint: expanded")
        try anchored(pill).withOffset(CGVector(dx: 0, dy: 150)).scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertTrue(pill.staticTexts["QA notch row 20"].waitForExistence(timeout: 3), "the 20th dictation is reachable")
        attachEvents("twenty-rows")
    }
}
