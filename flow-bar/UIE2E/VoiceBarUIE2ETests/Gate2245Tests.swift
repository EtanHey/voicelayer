import AppKit
import XCTest

extension VoiceBarFlowTests {
    func testHide1VisualFlow() throws {
        guard scenario == "hide1", gate2245Enabled else { throw NSError(domain: "HIDE1VIS requires gate build", code: 1) }
        limitations = ["HIDE1-only muted native visual gate with injected events; no audio, live daemon, global hotkeys, permissions or installed-app acceptance.",
            "Panel is positioned below the menu bar for unobstructed evidence; this does not establish notch placement."]
        ledger.requiredScope = ["gate:HIDE1"]
        for (index, event) in ["speaking", "preparing", "readback", "error", "reconnect", "notes", "wizard"].enumerated() {
            app.typeKey("0", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 1)
            step("HIDE1VIS " + event + " before") {
                let receipt = gateRead("gate-hide.json")
                XCTAssertEqual(receipt["action"] as? String, "start")
                XCTAssertEqual(receipt["panelVisible"] as? Bool, true)
                XCTAssertEqual(receipt["settingsVisible"] as? Bool, false)
                attachJSON("HIDE1VIS-" + event + "-before", receipt)
            }
            app.typeKey(String(index + 1), modifierFlags: .command)
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
                XCTAssertFalse(screenWindows.contains { ($0["owner"] as? String ?? "").lowercased().contains("voicebar") },
                    "VoiceBar-owned surface from any process remains on screen")
                attachJSON("HIDE1VIS-" + event + "-hidden", receipt)
            }
            app.typeKey("8", modifierFlags: .command)
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
        app.typeKey("9", modifierFlags: .command)
        ledger.verifiedSurfaces.insert("gate:HIDE1")
        completed = true
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
