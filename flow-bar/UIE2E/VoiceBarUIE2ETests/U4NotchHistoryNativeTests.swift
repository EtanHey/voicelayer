import AppKit
import XCTest

/// 2.3 lane U4, native only (pointer events): run on the M1 test rig, never on the M4. Not part of any
/// voicebar-ui-e2e.sh scenario (the runner's -only-testing names VoiceBarFlowTests); run it from that build's
/// xctestrun with -only-testing:VoiceBarUIE2ETests/U4NotchHistoryNativeTests. Fourteen seeded rows let the
/// extend handle reach its 12-row maximum.
final class U4NotchHistoryNativeTests: XCTestCase {
    func testTheExtendHandlePullsHistoryToTwelveRowsSnapsAndReopensAtItsHeight() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_ROOT"]))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".uie2e-sandbox")), "voicebar-ui-e2e-v1\n")
        let appURL = URL(fileURLWithPath: try XCTUnwrap(env["VOICEBAR_UIE2E_APP"]))
        guard Bundle(url: appURL)?.bundleIdentifier == "com.voicelayer.voicebar.uie2e",
              Bundle(url: appURL)?.object(forInfoDictionaryKey: "VoiceBarUIE2EOnly") as? Bool == true
        else { throw NSError(domain: "UIE2E unsafe app", code: 1) }
        // A GATE2245 build constructs the real AppDelegate and must launch through VoiceBarFlowTests' guarded
        // launcher (device tripwire + receipt). This test never launches one.
        guard Bundle(url: appURL)?.object(forInfoDictionaryKey: "UIE2EGate2245") as? Bool != true else {
            throw XCTSkip("U4 native test needs a standard UIE2E build, not a GATE2245 one")
        }
        let app = XCUIApplication(url: appURL)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let previousApp = NSWorkspace.shared.frontmostApplication
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_SCENARIO": "full", "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "QA_VOICE_DISABLE_FLAG_PATH": root.appendingPathComponent("disabled").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.u4.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path,
            "VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS": "14"]
        app.launch()
        defer { app.terminate(); previousApp?.activate() }
        enum PreconditionFailure: Error { case failed }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { XCTFail(message); throw PreconditionFailure.failed }
        }
        let pill = app.dialogs["VoiceBar QA Pill"]
        try require(pill.waitForExistence(timeout: 15), "the QA pill exists")
        let handle = pill.descendants(matching: .any)["notch-history-extend-handle"]

        // Evidence without pixels (the gatecap1 privacy guard bans screenshots in UIE2E tests): the handle's AX value
        // and the pill/handle frames at each state, as JSON.
        func shot(_ name: String) {
            func box(_ frame: CGRect) -> [String: Double] {
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            var record: [String: Any] = ["state": name, "pill": box(pill.frame)]
            if handle.exists {
                record["handle"] = box(handle.frame)
                record["rows"] = handle.value as? String ?? ""
            }
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            else { return }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "U4-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func openHistory() throws {
            // The host orders Settings out for U4. As in U2, a real click from Finder must leave it frontmost.
            finder.activate()
            try require(finder.wait(for: .runningForeground, timeout: 5), "Finder receives keyboard events")
            // Hover and click through Finder's anchor: pill.hover()/history.click() would activate VoiceBar QA
            // first, so neither Finder's state nor the host receipt could tell a product activation from XCUITest's.
            try require(pill.exists, "the QA pill")
            try XCTUnwrap(uie2eForegroundPoint(pill, via: finder), "Finder anchor").hover()
            let history = pill.buttons["History"]
            try require(history.waitForExistence(timeout: 4), "the launcher's History button")
            let beforeClicks = uie2eFirstClickReceipts(root).count
            try XCTUnwrap(uie2eForegroundPoint(history, via: finder), "Finder anchor").click()
            let clicks = Array(uie2eFirstClickReceipts(root).dropFirst(beforeClicks))
            try require(!clicks.isEmpty, "the host recorded the mouse-down on the pill")
            try require(clicks.allSatisfy { $0["appActive"] as? Bool == false && $0["pillKey"] as? Bool == false },
                        "History never activates VoiceBar or keys the pill at click time: \(clicks)")
            try require(finder.state == .runningForeground, "History never activates VoiceBar")
            try require(handle.waitForExistence(timeout: 4), "the open panel shows its extend handle")
            try require(pill.descendants(matching: .any).matching(identifier: "notch-history-extend-handle").count == 1,
                        "the handle identifier resolves uniquely")
        }
        func rows() -> String { handle.value as? String ?? "" }
        func waitForRows(_ expected: String) throws {
            let deadline = Date().addingTimeInterval(3)
            while rows() != expected, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            try require(rows() == expected, "expected \(expected), got \(rows())")
        }

        try openHistory()
        try waitForRows("7 of 12 rows")
        shot("1-open-7-rows")
        let initialOrigin = pill.frame.origin

        // Gestures stay on the Finder-anchored path: a user drags the handle with another app frontmost, and an
        // element-rooted gesture would activate VoiceBar QA mid-flow (8a36d965-era log: "Activate" before each).
        func anchored(_ element: XCUIElement) throws -> XCUICoordinate {
            try XCTUnwrap(uie2eForegroundPoint(element, via: finder), "Finder anchor")
        }
        let centre = try anchored(handle)
        centre.press(forDuration: 0.15, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: 7 * 46)))
        try waitForRows("12 of 12 rows")
        shot("2-pulled-12-rows")

        let extended = try anchored(handle)
        extended.press(forDuration: 0.15, thenDragTo: extended.withOffset(CGVector(dx: 0, dy: -2.4 * 46)))
        try waitForRows("10 of 12 rows")
        shot("3-released-between-rows-snaps-10")
        try require(abs(pill.frame.minX - initialOrigin.x) < 2 && abs(pill.frame.minY - initialOrigin.y) < 2,
                    "extending History never drags the pill window")

        try anchored(handle).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try require(rows() == "10 of 12 rows", "a click on the handle never moves it")

        let escapeStart = ProcessInfo.processInfo.systemUptime
        finder.typeKey(.escape, modifierFlags: [])
        let closed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: handle)], timeout: 3) == .completed
        let targetURL = root.appendingPathComponent("u4-escape-target.json")
        let target = try Data(contentsOf: targetURL)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: target) as? [String: Any])
        let attachment = XCTAttachment(data: target, uniformTypeIdentifier: "public.json")
        attachment.name = "U4-escape-event-target"
        attachment.lifetime = .keepAlways
        add(attachment)
        try require((receipt["eventTimestamp"] as? Double ?? 0) >= escapeStart, "the Escape receipt is fresh")
        try require(receipt["source"] as? String == "global", "Escape reached the real global monitor path")
        try require(receipt["voiceBarKeyWindowNumber"] as? Int == 0, "no VoiceBar window owned Escape")
        try require(closed, "Esc from the foreground app closes History")
        shot("4-closed")

        try openHistory()
        try waitForRows("10 of 12 rows")
        shot("5-reopened-keeps-10-rows")
    }
}
