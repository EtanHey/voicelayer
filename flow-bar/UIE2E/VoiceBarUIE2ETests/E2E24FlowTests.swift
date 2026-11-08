import XCTest

// Uses the existing guarded QA launcher, boundary broker, action ledger and still capture.
// Native execution belongs to the M1 lead. Missing sibling fixtures skip with their owner.
extension VoiceBarFlowTests {
    func testE2E24AllFlows() throws {
        ledger.requiredScope = ["e2e24"]
        try testE2E24UnifiedSettingsDictionary()
        try testE2E24UnifiedSettingsRecognizer()
        try testE2E24HistoryAllActions()
        try testE2E24PlaybackPauseResumeSeekReplay()
        try testE2E24MuteKeepsSameTake()
        try testE2E24HistoryFallback()
        try testE2E24QueuedSpinnerCancel()
        try testE2E24HideRecording()
        try testE2E24TypedFeedback()
        try testE2E24MicPriorityReorder()
        try testE2E24PermissionRevocation()
        try testE2E24HistorySixEightTwentyRows()
        try testE2E24RecordingWingMicAndClock()
        try testE2E24RecordAfterRecordKeepsBothTakes()
        try testE2E24EveryHistoryScopeAction()
        try testE2E24EveryControlTooltipHover()
        try testE2E24HistoryDragUpCloses()
        try testE2E24NarrationLayerSpeakAskRead()
        step("2.4 every declared flow completed") {
            XCTAssertEqual(testRun?.failureCount ?? 1, 0)
            if (testRun?.failureCount ?? 1) == 0 { ledger.verifiedSurfaces.insert("e2e24") }
        }
        completed = true
    }

    func e2e24Fixture(_ name: String, owner: String) throws {
        let fixture = app.buttons["qa-fixture-2.4-" + name]
        guard fixture.exists else { throw XCTSkip(owner + ": missing 2.4 QA fixture " + name) }
        click(fixture)
        receipt("fixture:2.4-" + name)
    }

    func e2e24Command(_ label: String, event: String) {
        let before = fixtureEvents().count
        click(app.dialogs["VoiceBar QA Pill"].descendants(matching: .button)[label])
        step("2.4 " + label + " dispatches " + event) {
            waitUntil { self.fixtureEvents().dropFirst(before).contains(event) }
        }
    }

    func testE2E24UnifiedSettingsDictionary() throws {
        try e2e24Fixture("settings", owner: "pending-lane-A")
        dictionaryFlow()
    }

    func testE2E24UnifiedSettingsRecognizer() throws {
        try e2e24Fixture("settings", owner: "pending-lane-A")
        transcriptionFlow()
    }

    func testE2E24HistoryAllActions() throws {
        try e2e24Fixture("history", owner: "pending-lane-A")
        historyFlow()
    }

    func testE2E24PlaybackPauseResumeSeekReplay() throws {
        try e2e24Fixture("speaking", owner: "pending-lane-B")
        e2e24Command("Pause", event: "command:pause")
        e2e24Command("Resume", event: "command:resume")
        let word = app.dialogs["VoiceBar QA Pill"].buttons["qa-word-2"]
        let before = fixtureEvents().count
        click(word)
        step("2.4 word seek dispatch") {
            waitUntil { self.fixtureEvents().dropFirst(before).contains("command:seek") }
        }
        try e2e24Fixture("readback", owner: "pending-lane-B")
        e2e24Command("Replay", event: "command:replay")
    }

    func testE2E24MuteKeepsSameTake() throws {
        try e2e24Fixture("recording", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        let take = pill.value as? String
        e2e24Command("Mute", event: "command:mute")
        step("2.4 mute preserves recording identity") {
            XCTAssertNotNil(take)
            XCTAssertEqual(pill.value as? String, take)
            XCTAssertTrue(pill.buttons["Unmute"].exists)
            XCTAssertTrue(pill.buttons["Stop"].exists)
        }
        e2e24Command("Unmute", event: "command:unmute")
        step("2.4 unmute preserves recording identity") { XCTAssertEqual(pill.value as? String, take) }
    }
    func testE2E24HistoryFallback() throws {
        try e2e24Fixture("paste-failed", owner: "pending-lane-A")
        e2e24Command("Open History", event: "command:history")
    }
    func testE2E24QueuedSpinnerCancel() throws {
        try e2e24Fixture("queued", owner: "pending-lane-A")
        e2e24Command("Cancel", event: "command:cancel")
    }
    func testE2E24HideRecording() throws {
        try e2e24Fixture("recording", owner: "pending-lane-A")
        e2e24Command("Hide", event: "command:hide")
    }
    func testE2E24TypedFeedback() throws {
        try e2e24Fixture("typed-feedback", owner: "pending-lane-A")
        e2e24Command("Send", event: "command:typed_feedback")
    }
    func testE2E24MicPriorityReorder() throws {
        try e2e24Fixture("microphone-priority", owner: "pending-lane-A")
        e2e24Command("Move microphone up", event: "command:microphone_priority")
    }
    func testE2E24PermissionRevocation() throws {
        try e2e24Fixture("permission-revoked", owner: "pending-lane-A")
        e2e24Command("Check permissions", event: "command:permission_health")
    }
    func testE2E24HistoryDragClose() throws {
        try e2e24Fixture("history-expanded", owner: "pending-lane-A")
        e2e24Command("Close History", event: "command:history_close")
    }
    func testE2E24HistorySixEightTwentyRows() throws {
        try e2e24Fixture("history-20", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        func visibleRows() -> Int {
            pill.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-row-'")).allElementsBoundByIndex.filter { $0.isHittable }.count
        }
        step("2.4 collapsed History shows six rows") { XCTAssertEqual(visibleRows(), 6) }
        click(pill.buttons["Expand History"])
        step("2.4 expanded History shows eight rows") { XCTAssertEqual(visibleRows(), 8) }
        step("2.4 scroll reaches twentieth retained row") {
            try mutate { pill.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1200) }
            XCTAssertTrue(pill.buttons["history-row-20"].isHittable)
        }
    }

    func testE2E24RecordingWingMicAndClock() throws {
        try e2e24Fixture("recording-long-microphone-name", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        step("2.4 microphone name remains one line beside elapsed time") {
            let mic = pill.staticTexts["recording-microphone-name"]
            let clock = pill.staticTexts["recording-elapsed-time"]
            XCTAssertTrue(mic.exists)
            XCTAssertTrue(clock.exists)
            XCTAssertLessThanOrEqual(mic.frame.height, 24)
            XCTAssertFalse(mic.frame.intersects(clock.frame))
        }
    }

    func testE2E24RecordAfterRecordKeepsBothTakes() throws {
        try e2e24Fixture("record-after-record", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        step("2.4 both takes survive overlapping processing") {
            XCTAssertTrue(pill.descendants(matching: .any)["queued-take-1"].exists)
            XCTAssertTrue(pill.descendants(matching: .any)["recording-take-2"].exists)
        }
    }
    func testE2E24EveryHistoryScopeAction() throws {
        for scope in ["dictation", "ask", "speak"] {
            try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
            for (label, command) in [("Play", "play"), ("Copy", "copy"), ("Paste", "paste"),
                                      ("Re-transcribe", "retranscribe"), ("Details", "details")] {
                e2e24Command(label, event: "history:" + scope + ":" + command)
            }
            step("2.4 " + scope + " timestamp and day heading") {
                let pill = app.dialogs["VoiceBar QA Pill"]
                XCTAssertEqual(pill.staticTexts["history-day-header"].label, "Today")
                XCTAssertEqual(pill.staticTexts["history-timestamp"].label, "13:05")
            }
        }
    }

    func testE2E24EveryControlTooltipHover() throws {
        for surface in ["launcher", "recording", "transcribing", "speaking", "readback", "history", "settings"] {
            try e2e24Fixture("tooltips-" + surface, owner: "pending-lane-A")
            let buttons = app.dialogs["VoiceBar QA Pill"].buttons.allElementsBoundByIndex.filter { $0.isHittable }
            step("2.4 " + surface + " has controls to hover") { XCTAssertFalse(buttons.isEmpty) }
            for button in buttons {
                step("2.4 hover " + button.identifier) {
                    try mutate { button.hover() }
                    let tooltip = app.descendants(matching: .any)["tooltip-" + button.identifier]
                    XCTAssertTrue(tooltip.waitForExistence(timeout: 3))
                    XCTAssertFalse(tooltip.label.isEmpty)
                }
            }
        }
    }

    func testE2E24HistoryDragUpCloses() throws {
        try e2e24Fixture("history-expanded", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        let handle = pill.descendants(matching: .any)["notch-history-extend-handle"]
        step("2.4 drag up closes History") {
            let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: -160))
            try mutate { start.press(forDuration: 0.1, thenDragTo: end) }
            waitUntil { !pill.buttons["history-row-1"].exists }
        }
    }
    func testE2E24NarrationLayerSpeakAskRead() throws {
        for operation in ["speak", "ask", "read"] {
            try e2e24Fixture("narration-" + operation, owner: "pending-lane-B")
            step("2.4 " + operation + " uses the NarrationLayer audio and timing contract") {
                let pill = app.dialogs["VoiceBar QA Pill"]
                XCTAssertEqual(pill.staticTexts["narration-origin"].label, "NarrationLayer")
                XCTAssertTrue(pill.buttons["qa-word-2"].exists)
            }
        }
    }
}
