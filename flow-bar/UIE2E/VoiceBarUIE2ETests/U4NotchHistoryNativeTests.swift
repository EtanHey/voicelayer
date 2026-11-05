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
        app.launchEnvironment = ["VOICEBAR_UIE2E": "1", "VOICEBAR_UIE2E_SCENARIO": "full", "VOICEBAR_UIE2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path, "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "QA_VOICE_DISABLE_FLAG_PATH": root.appendingPathComponent("disabled").path,
            "VOICEBAR_USER_DEFAULTS_SUITE": "com.voicelayer.uie2e.u4.\(root.lastPathComponent)",
            "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
            "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path,
            "VOICEBAR_UIE2E_NOTCH_HISTORY_ROWS": "14"]
        app.launch()
        defer { app.terminate() }
        let pill = app.dialogs["VoiceBar QA Pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
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
        func openHistory() {
            pill.hover()
            let history = pill.buttons["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 4), "the launcher's History button")
            history.click()
        }
        func rows() -> String { handle.value as? String ?? "" }
        func waitForRows(_ expected: String) {
            let deadline = Date().addingTimeInterval(3)
            while rows() != expected, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(rows(), expected)
        }

        openHistory()
        XCTAssertTrue(handle.waitForExistence(timeout: 4), "the open panel shows its extend handle")
        waitForRows("7 of 12 rows")
        shot("1-open-7-rows")

        let centre = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.15, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: 7 * 46)))
        waitForRows("12 of 12 rows")
        shot("2-pulled-12-rows")

        let extended = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        extended.press(forDuration: 0.15, thenDragTo: extended.withOffset(CGVector(dx: 0, dy: -2.4 * 46)))
        waitForRows("10 of 12 rows")
        shot("3-released-between-rows-snaps-10")

        handle.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(rows(), "10 of 12 rows", "a click on the handle never moves it")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: handle)], timeout: 3), .completed, "Esc closes History")
        shot("4-closed")

        openHistory()
        XCTAssertTrue(handle.waitForExistence(timeout: 4))
        waitForRows("10 of 12 rows")
        shot("5-reopened-keeps-10-rows")
    }
}
