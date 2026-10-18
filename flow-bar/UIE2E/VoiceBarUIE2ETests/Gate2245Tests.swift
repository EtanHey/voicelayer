import AppKit
import XCTest

// BEGIN GATE2245 WINDOW OWNERSHIP
func gate2245HasOwnedScreenWindows(_ screenWindows: [[String: Any]], pid: Int) -> Bool {
    screenWindows.contains { ($0["pid"] as? Int) == pid }
}
// END GATE2245 WINDOW OWNERSHIP

// BEGIN UIE2E FIXTURE COMMANDS
// Mirrors UIE2EFixtureCommand in the QA app. A name-only distributed notification is the one
// channel the sandboxed runner can send that no global macOS shortcut can intercept.
let uie2eFixtureCommandPrefix = "com.voicelayer.voicebar.uie2e.command."
func uie2eFixtureCommandName(token: String, command: String) -> String { uie2eFixtureCommandPrefix + token + "." + command }
/// The QA app's acknowledgement (count, command), or nil when absent/unreadable.
func uie2eFixtureAck(_ data: Data?) -> (count: Int, name: String)? {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let count = object["count"] as? Int, let name = object["name"] as? String else { return nil }
    return (count, name)
}
/// True only when a receipt was written by exactly this delivered command.
func uie2eReceiptIsFrom(_ receipt: [String: Any], count: Int, name: String) -> Bool {
    let command = receipt["fixtureCommand"] as? [String: Any]
    return command?["count"] as? Int == count && command?["name"] as? String == name
}
// END UIE2E FIXTURE COMMANDS

// BEGIN GATE2246 RENDERED WORDS
func gate2246TeleprompterContains(_ pill: XCUIElement, text: String) -> Bool {
    let expected = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !expected.isEmpty else { return false }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
        let rendered = pill.staticTexts.allElementsBoundByIndex.flatMap { element -> [String] in
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = label.isEmpty ? (element.value as? String ?? "") : label
            return content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        // Require contiguous whole words, so "B" cannot pass for a stale "Bogus".
        if rendered.count >= expected.count,
           (0...(rendered.count - expected.count)).contains(where: { start in
               Array(rendered[start..<(start + expected.count)]) == expected
           }) { return true }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        Thread.sleep(forTimeInterval: min(0.05, remaining))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}
// END GATE2246 RENDERED WORDS

// BEGIN GATE2246 MODAL QUERIES
func gate2246Alert(_ app: XCUIApplication) -> XCUIElement {
    app.dialogs.containing(.staticText, identifier: "VoiceLayer microphone permission needs attention").firstMatch
}

func gate2246LaterButtons(_ app: XCUIApplication) -> XCUIElementQuery {
    // NSAlert's NSButton exposes AXTitle, with an empty AXLabel on macOS.
    // Keep the product-dialog scope: Touch Bar also exposes a Later button.
    gate2246Alert(app).buttons.matching(NSPredicate(format: "title == %@", "Later"))
}

func gate2246ModalObservation(_ app: XCUIApplication) -> [String: Any] {
    let alert = gate2246Alert(app)
    let visible = alert.exists
    return ["alertVisible": visible,
            "panelVisible": app.dialogs["VoiceBar GATE2245 Product Pill"].exists,
            "alertText": visible ? alert.staticTexts.allElementsBoundByIndex.map(\.label) : [],
            "laterButtonCount": visible ? gate2246LaterButtons(app).count : 0]
}
// END GATE2246 MODAL QUERIES

extension VoiceBarFlowTests {
    func testGate2246Flow() throws {
        guard scenario == "gate2246", gate2245Enabled else { throw NSError(domain: "GATE2246 requires gate build", code: 1) }
        limitations = ["Focused muted native gate: real panels and NSAlert, synthetic wire/selection; no capture, daemon launch, physical hotkeys, permissions or installed-app acceptance."]
        ledger.requiredScope = ["gate:HIDE1.1", "gate:SEL1.x"]
        step("GATE2246 no-device guard installed before fixtures") {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches))
        }
        func command(_ name: String) { _ = fixtureCommand(name) }
        func alertPresent() -> Bool { gate2246Alert(app).exists }
        func waitForAlert(_ expected: Bool) {
            let appeared = gate2246Alert(app).waitForExistence(timeout: expected ? 3 : 1)
            XCTAssertEqual(appeared, expected)
        }
        func dismissAlert() {
            let buttons = gate2246LaterButtons(app)
            guard buttons.count == 1 else { XCTFail("Expected one Later in product alert"); return }
            buttons.firstMatch.click()
            XCTAssertTrue(gate2246Alert(app).waitForNonExistence(timeout: 3))
        }
        for name in ["user-f5", "user-ask", "unknown", "background", "recovered", "visible"] {
            command("start")
            step("GATE2246 HIDE " + name + " before") {
                XCTAssertTrue(app.dialogs["VoiceBar GATE2245 Product Pill"].waitForExistence(timeout: 3))
                XCTAssertFalse(alertPresent())
            }
            command(name)
            let immediate = !["background", "recovered"].contains(name)
            step("GATE2246 HIDE " + name + " failure") {
                waitForAlert(immediate)
                let observation = gate2246ModalObservation(app).merging(["case": name, "phase": "failure"]) { _, new in new }
                XCTAssertEqual(observation["alertVisible"] as? Bool, immediate)
                XCTAssertEqual(observation["panelVisible"] as? Bool, name == "visible")
                if immediate { XCTAssertEqual(observation["laterButtonCount"] as? Int, 1) }
                attachJSON("GATE2246-" + name + "-failure-AX", observation)
            }
            if immediate { step("GATE2246 HIDE " + name + " dismiss Later") { dismissAlert() } }
            command("show")
            step("GATE2246 HIDE " + name + " shown") {
                waitForAlert(name == "background")
                let observation = gate2246ModalObservation(app).merging(["case": name, "phase": "shown"]) { _, new in new }
                XCTAssertEqual(observation["alertVisible"] as? Bool, name == "background")
                XCTAssertTrue(app.dialogs["VoiceBar GATE2245 Product Pill"].waitForExistence(timeout: 3))
                attachJSON("GATE2246-" + name + "-shown-AX", observation)
            }
            if name == "background" { step("GATE2246 HIDE background dismiss Later") { dismissAlert() } }
        }
        ledger.verifiedSurfaces.insert("gate:HIDE1.1")
        command("selection")
        for (name, expected, text) in [("same-hash", ["stop"], ""),
            ("different", ["speak_text"], "Replacement selection B"),
            ("pending", ["speak_text"], "Own selection B"),
            ("fast-bc", ["speak_text", "speak_text"], "Own selection C"),
            ("no-hash", ["speak_text"], "Replacement selection B"),
            ("busy", [], "")] {
            let sent = fixtureCommand(name)
            step("GATE2246 SEL " + name) {
                // A swallowed command must fail as "not delivered", never as a stale product receipt.
                waitUntil { uie2eReceiptIsFrom(self.gateRead("gate-hide.json"), count: sent, name: name) }
                let receipt = gateRead("gate-hide.json")
                XCTAssertTrue(uie2eReceiptIsFrom(receipt, count: sent, name: name), "Receipt is not from command " + name)
                XCTAssertEqual(receipt["action"] as? String, "selection:" + name)
                let messages = receipt["commands"] as? [[String: Any]] ?? []
                XCTAssertEqual(messages.compactMap { $0["cmd"] as? String }, expected)
                for message in messages where message["cmd"] as? String == "speak_text" {
                    XCTAssertFalse((message["id"] as? String ?? "").isEmpty)
                    XCTAssertEqual((message["text_hash"] as? String)?.count, 64)
                }
                if !text.isEmpty {
                    XCTAssertEqual(receipt["statusText"] as? String, text)
                    let pill = app.dialogs["VoiceBar GATE2245 Product Pill"]
                    XCTAssertTrue(gate2246TeleprompterContains(pill, text: text),
                        "Current teleprompter text missing: " + text)
                }
                if name == "busy" {
                    XCTAssertTrue(app.staticTexts["Busy transcribing. Selection not read"].exists)
                }
                attachJSON("GATE2246-selection-" + name, receipt)
            }
        }
        ledger.verifiedSurfaces.insert("gate:SEL1.x")
        command("end")
        step("GATE2246 no device-start or process tripwire invoked") {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches))
        }
        completed = true
    }

    func testHide1VisualFlow() throws {
        guard scenario == "hide1", gate2245Enabled else { throw NSError(domain: "HIDE1VIS requires gate build", code: 1) }
        limitations = ["HIDE1-only muted native visual gate with injected events; no audio, live daemon, global hotkeys, permissions or installed-app acceptance.",
            "Panel is positioned below the menu bar for unobstructed evidence; this does not establish notch placement."]
        ledger.requiredScope = ["gate:HIDE1"]
        step("HIDE1VIS no-device guard installed before fixtures") {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches))
        }
        for event in ["speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard"] {
            fixtureCommand("start")
            Thread.sleep(forTimeInterval: 1)
            step("HIDE1VIS " + event + " before") {
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["action"] as? String, "start")
                XCTAssertEqual(receipt["panelVisible"] as? Bool, true)
                XCTAssertEqual(receipt["settingsVisible"] as? Bool, false)
                attachJSON("HIDE1VIS-" + event + "-before", receipt)
            }
            fixtureCommand(event)
            Thread.sleep(forTimeInterval: 1)
            step("HIDE1VIS " + event + " hidden") {
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["action"] as? String, "hidden:" + event)
                XCTAssertEqual(receipt["snoozed"] as? Bool, true)
                XCTAssertEqual(receipt["hidden"] as? Bool, true)
                XCTAssertEqual(receipt["panelVisible"] as? Bool, false)
                XCTAssertEqual(receipt["visiblePanels"] as? [String], [])
                XCTAssertEqual(receipt["wizardVisible"] as? Bool, false)
                XCTAssertEqual((receipt["ownedVisibleWindows"] as? [[String: Any]])?.count, 0)
                let screenWindows = receipt["screenWindows"] as? [[String: Any]] ?? []
                guard let qaPID = receipt["pid"] as? Int, qaPID > 0 else {
                    XCTFail("QA process identity missing or invalid")
                    return
                }
                XCTAssertFalse(gate2245HasOwnedScreenWindows(screenWindows, pid: qaPID),
                    "QA-owned surface remains on screen; installed resident is checked separately")
                attachJSON("HIDE1VIS-" + event + "-hidden", receipt)
            }
            fixtureCommand("show")
            Thread.sleep(forTimeInterval: 1)
            step("HIDE1VIS " + event + " shown") {
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["action"] as? String, "show")
                XCTAssertEqual(receipt["panelVisible"] as? Bool, true)
                XCTAssertEqual(receipt["snoozed"] as? Bool, false)
                var expected = receipt["beforeShow"] as? [String: Any] ?? [:]
                if expected["mode"] as? String == "disconnected", receipt["connected"] as? Bool == true { expected["mode"] = "idle" }
                XCTAssertEqual(receipt["state"] as? NSDictionary, expected as NSDictionary)
                XCTAssertEqual(receipt["wizardVisible"] as? Bool, event == "wizard")
                attachJSON("HIDE1VIS-" + event + "-shown", receipt)
            }
        }
        fixtureCommand("end")
        ledger.verifiedSurfaces.insert("gate:HIDE1")
        step("HIDE1VIS no device-start or process tripwire invoked") {
            XCTAssertTrue(guardReceiptIsClean(guardLaunches))
        }
        completed = true
    }

    /// Posts one fixture command and waits for the QA app's acknowledgement; returns its count.
    @discardableResult
    func fixtureCommand(_ name: String) -> Int {
        let ack = root.appendingPathComponent("fixture-command-ack.json")
        let before = uie2eFixtureAck(try? Data(contentsOf: ack))?.count ?? 0
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(uie2eFixtureCommandName(token: root.lastPathComponent, command: name)),
            object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let observed = uie2eFixtureAck(try? Data(contentsOf: ack)), observed.count == before + 1 {
                XCTAssertEqual(observed.name, name, "Fixture command acknowledged out of order")
                return observed.count
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("Fixture command not delivered: " + name)
        return before + 1
    }

    func gateRead(_ file: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(file)))) as? [String: Any] ?? [:]
    }

    func gate2245Flow() {
        let required: Set<String> = ["gate:HIDE1", "gate:SEL1", "gate:CLN1b"]
        ledger.requiredScope.formUnion(required)
        activePage = "GATE2245"
        click(app.buttons["qa-fixture-idle"])
        click(app.buttons["qa-fixture-gate-hide-start"], "HIDE1 create real product panel")
        step("HIDE1 real panel visible before snooze") {
            XCTAssertTrue(app.dialogs["VoiceBar GATE2245 Product Pill"].waitForExistence(timeout: 3))
            XCTAssertEqual(gateRead("gate-hide.json")["panelVisible"] as? Bool, true)
        }
        let hideFailures = testRun?.failureCount ?? 0
        for event in ["speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard"] {
            click(app.buttons["qa-fixture-gate-hide-" + event], "HIDE1 snooze then " + event)
            step("HIDE1 all real panels remain hidden after " + event) {
                waitUntil { self.gateRead("gate-hide.json")["action"] as? String == "hidden:" + event }
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["snoozed"] as? Bool, true)
                XCTAssertEqual(receipt["hidden"] as? Bool, true)
                XCTAssertEqual(receipt["panelVisible"] as? Bool, false)
                XCTAssertEqual(receipt["visiblePanels"] as? [String], [])
                XCTAssertEqual(receipt["wizardVisible"] as? Bool, false)
                XCTAssertFalse(app.dialogs["VoiceBar GATE2245 Product Pill"].exists)
                XCTAssertFalse(app.dialogs["VoiceBar QA Pill"].exists)
                XCTAssertFalse(app.windows["VoiceBar QA Setup"].exists)
                attachJSON("GATE2245-HIDDEN-" + event, receipt)
            }
            click(app.buttons["qa-fixture-gate-hide-show"], "HIDE1 Show current " + event)
            step("HIDE1 Show restores current state after " + event) {
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["action"] as? String, "show")
                XCTAssertEqual(receipt["panelVisible"] as? Bool, true)
                XCTAssertEqual(receipt["snoozed"] as? Bool, false)
                XCTAssertEqual(receipt["hidden"] as? Bool, false)
                var expected = receipt["beforeShow"] as? [String: Any] ?? [:]
                // Snooze's disconnected sentinel returns to idle on a live connection.
                if expected["mode"] as? String == "disconnected", receipt["connected"] as? Bool == true {
                    expected["mode"] = "idle"
                }
                XCTAssertEqual(receipt["state"] as? NSDictionary, expected as NSDictionary)
                XCTAssertTrue(app.dialogs["VoiceBar GATE2245 Product Pill"].exists)
                if event == "wizard" {
                    XCTAssertTrue(app.windows["VoiceBar QA Setup"].waitForExistence(timeout: 3))
                    XCTAssertEqual(receipt["wizardVisible"] as? Bool, true)
                }
                attachJSON("GATE2245-SHOWN-" + event, receipt)
            }
            if event == "wizard" { wizardFlow() } // Resolve the owned wizard before Settings input.
        }
        if (testRun?.failureCount ?? 0) == hideFailures { ledger.verifiedSurfaces.insert("gate:HIDE1") }
        click(app.buttons["qa-fixture-gate-hide-end"], "HIDE1 close only gate panels")

        let selectionFailures = testRun?.failureCount ?? 0
        for name in ["same", "empty", "failed"] {
            click(app.buttons["qa-fixture-gate-state-" + name], "SEL1 preparing " + name + " selection")
            step("SEL1 " + name + " selection dispatches only Stop") {
                let receipt = gateRead("gate-selection.json")
                XCTAssertEqual(receipt["case"] as? String, name)
                let messages = receipt["commands"] as? [[String: Any]] ?? []
                XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages.first?["cmd"] as? String, "stop")
                attachJSON("GATE2245-SELECTION-" + name, receipt)
            }
        }
        step("SEL1 busy note visible in real BarView") {
            app.buttons["qa-fixture-gate-state-busy"].click()
            let note = app.dialogs["VoiceBar QA Pill"].staticTexts["Busy transcribing. Selection not read"]
            XCTAssertTrue(note.waitForExistence(timeout: 1))
            if note.exists { XCTAssertGreaterThan(note.frame.height, 0) }
        }
        if (testRun?.failureCount ?? 0) == selectionFailures {
            ledger.verifiedSurfaces.insert("gate:SEL1")
        }
        let timingFailures = testRun?.failureCount ?? 0
        for kind in ["partial", "untimed", "edge"] {
            click(app.buttons["qa-fixture-gate-state-" + kind], "CLN1b " + kind + " subtitle payload")
            step("CLN1b " + kind + " word controls and timing notice") {
                let pill = app.dialogs["VoiceBar QA Pill"]
                XCTAssertTrue(pill.exists)
                for word in ["Alpha", "Bravo", "Charlie", "Delta"] {
                    let timed = kind == "edge" || kind == "partial" && ["Alpha", "Charlie"].contains(word)
                    XCTAssertEqual(pill.buttons[word].exists, timed, word + " seekability")
                    if timed { XCTAssertTrue(pill.buttons[word].isEnabled) }
                    else { XCTAssertTrue(pill.staticTexts[word].exists, word + " untimed text missing") }
                }
                XCTAssertEqual(pill.staticTexts["Word timing unavailable"].exists, kind == "untimed")
                attachJSON("GATE2245-TIMING-" + kind, ["AX": pill.debugDescription])
            }
            if kind == "partial" {
                step("CLN1b timed Charlie dispatches exact 2000ms seek") {
                    let before = fixtureEvents().count
                    app.dialogs["VoiceBar QA Pill"].buttons["Charlie"].click()
                    waitUntil { self.fixtureEvents().dropFirst(before).contains("command:seek") }
                    let messages = gateRead("commands.json")["messages"] as? [[String: Any]]
                    XCTAssertEqual(messages?.last?["offset_ms"] as? Int, 2000)
                }
            }
        }
        if (testRun?.failureCount ?? 0) == timingFailures { ledger.verifiedSurfaces.insert("gate:CLN1b") }
        click(app.buttons["qa-fixture-idle"])
        step("GATE2245 all focused surfaces verified") {
            XCTAssertTrue(required.isSubset(of: ledger.verifiedSurfaces))
        }
    }
}
