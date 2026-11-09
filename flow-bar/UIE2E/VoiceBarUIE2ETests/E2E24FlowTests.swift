import AppKit
import XCTest

// Uses the existing guarded QA launcher, boundary broker, action ledger and still capture.
// Native execution belongs to the M1 lead. Missing sibling fixtures skip with their owner.
extension VoiceBarFlowTests {
    func testE2E24AllFlows() throws {
        var cases: [(String, () throws -> Void)] = [
            ("N1", testN1SettingsContainControlsInsteadOfWindowHandoffs),
            ("N4", testN4BothDrawersTrackUpwardAndCloseOnRelease),
            ("N5", testN5QuickHandleGrabMatchesSlowGrab),
            ("N6", testN6SettingsPullHintDoesNotCoverHistoryRows),
            ("N7", testN7DrawersAreReachableInAllNonSpeechStates),
            ("N9", testN9MicrophoneControlIsConsistentAcrossAllowedStates),
            ("N10", testN10RecordingWaveformSitsCloseToTimer),
            ("T1", testT1QueueBackAndForwardSitBesidePause),
            ("T2", testT2HeightHandleIsBelowEyeReplayRow),
            ("T4", testT4EyeAndReplayFormOneCentredGroup),
            ("T5", testT5SpeakingWingHasAudioWaveformAndTime),
            ("T6", testT6SpeedIsInTopPlaybackRow),
            ("T7", testT7StopMovesBesideEyeRow),
            ("T8", testT8ScrubberIsCloseToEyeReplayRow),
            ("dictionary", testE2E24UnifiedSettingsDictionary),
            ("recognizer", testE2E24UnifiedSettingsRecognizer),
            ("history", testE2E24HistoryAllActions),
            ("playback", testE2E24PlaybackPauseResumeSeekReplay),
            ("replay", testE2E24Replay),
            ("mute", testE2E24MuteKeepsSameTake),
            ("fallback", testE2E24HistoryFallback),
            ("queue", testE2E24QueuedSpinnerCancel),
            ("hide", testE2E24HideRecording),
            ("typed", testE2E24TypedFeedback),
            ("microphone", testE2E24MicPriorityReorder),
            ("permissions", testE2E24PermissionRevocation),
            ("detents", testE2E24HistorySixEightTwentyRows),
            ("wing", testE2E24RecordingWingMicAndClock),
            ("takes", testE2E24RecordAfterRecordKeepsBothTakes),
            ("drag", testE2E24HistoryDragUpCloses)
        ]
        for scope in ["dictation", "ask", "speak"] {
            cases.append(("history-" + scope, { try self.e2e24HistoryScope(scope) }))
        }
        for surface in ["launcher", "recording", "transcribing", "speaking", "readback", "history", "settings"] {
            cases.append(("tooltip-" + surface, { try self.e2e24Tooltip(surface) }))
        }
        for operation in ["speak", "ask", "read"] {
            cases.append(("narration-" + operation, { try self.e2e24Narration(operation) }))
        }
        ledger.requiredScope = Set(cases.map { "e2e24:" + $0.0 })
        for (name, run) in cases {
            let before = testRun?.failureCount ?? 0
            let started = Date()
            do {
                try run()
                if (testRun?.failureCount ?? 1) == before && UIE2EKnownIssue(rawValue: name) == nil { ledger.verifiedSurfaces.insert("e2e24:" + name) }
            } catch let pending as XCTSkip {
                let owner = name == "playback" || name == "replay" || name.hasPrefix("narration-") ? "pending-lane-B" : "pending-lane-A"
                step("2.4 pending " + name + ": " + String(describing: pending), skipped: owner) {}
            } catch {
                step("2.4 failed " + name) { XCTFail(String(describing: error)) }
            }
            attachJSON("E2E24-TIMING-" + name, ["case": name, "seconds": Date().timeIntervalSince(started)])
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
        dictionaryFlow()
    }

    func testE2E24UnifiedSettingsRecognizer() throws {
        transcriptionFlow()
    }

    func testE2E24HistoryAllActions() throws {
        historyFlow()
    }

    func testE2E24PlaybackPauseResumeSeekReplay() throws {
        try e2e24Fixture("speaking", owner: "pending-lane-B")
        e2e24Command("Pause", event: "command:pause")
        step("2.4 pause exposes resume") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].buttons["Resume"].exists) }
        e2e24Command("Resume", event: "command:resume")
        step("2.4 resume exposes pause") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].buttons["Pause"].exists) }
        let word = app.dialogs["VoiceBar QA Pill"].buttons["qa-word-2"]
        let before = fixtureEvents().count
        click(word)
        step("2.4 word seek dispatch") {
            waitUntil { self.fixtureEvents().dropFirst(before).contains("command:speech_seek") }
            waitUntil { self.app.dialogs["VoiceBar QA Pill"].staticTexts["playback-word-index"].label == "2" }
        }
    }

    func testE2E24Replay() throws {
        try e2e24Fixture("readback", owner: "pending-lane-B")
        e2e24Command("Replay", event: "command:replay")
        step("2.4 replay is speaking") { XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].buttons["Pause"].waitForExistence(timeout: 3)) }
    }

    func testE2E24MuteKeepsSameTake() throws {
        try e2e24Fixture("recording", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        let take = pill.staticTexts["recording-take-id"].label
        click(pill.buttons["Mute"])
        step("2.4 mute preserves recording identity") {
            XCTAssertFalse(take.isEmpty)
            XCTAssertEqual(pill.staticTexts["recording-take-id"].label, take)
            XCTAssertTrue(pill.buttons["Unmute"].exists)
            XCTAssertTrue(pill.buttons["Stop"].exists)
        }
        click(pill.buttons["Unmute"])
        step("2.4 unmute preserves recording identity") { XCTAssertEqual(pill.staticTexts["recording-take-id"].label, take) }
    }
    func testE2E24HistoryFallback() throws {
        try e2e24Fixture("paste-failed", owner: "pending-lane-A")
        click(app.dialogs["VoiceBar QA Pill"].buttons["VoiceBarNotchFeedback.openHistory"])
        step("2.4 fallback opens History") {
            XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].buttons["history-row-1"].waitForExistence(timeout: 3))
        }
    }
    func testE2E24QueuedSpinnerCancel() throws {
        try e2e24Fixture("queued", owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        step("2.4 queued spinner visible") { XCTAssertTrue(pill.descendants(matching: .any)["queued-spinner"].exists) }
        e2e24Command("Cancel", event: "command:cancel")
        step("2.4 cancel retains archived take") {
            XCTAssertTrue(app.descendants(matching: .any)["archived-take-1"].exists)
            XCTAssertFalse(pill.descendants(matching: .any)["queued-spinner"].exists)
        }
    }
    func testE2E24HideRecording() throws {
        try e2e24Fixture("recording", owner: "pending-lane-A")
        click(app.dialogs["VoiceBar QA Pill"].buttons["Hide"])
        step("2.4 hidden pill retains its take") {
            waitUntil { !self.app.dialogs["VoiceBar QA Pill"].exists }
            XCTAssertTrue(app.descendants(matching: .any)["archived-take-1"].exists)
            XCTAssertTrue(fixtureEvents().contains("hide"))
        }
    }
    func testE2E24TypedFeedback() throws {
        try e2e24Fixture("typed-feedback", owner: "pending-lane-A")
        click(app.dialogs["VoiceBar QA Pill"].buttons["Send"])
        step("2.4 feedback is visibly accepted") {
            XCTAssertTrue(app.dialogs["VoiceBar QA Pill"].staticTexts["feedback-sent"].waitForExistence(timeout: 3))
        }
    }
    func testE2E24MicPriorityReorder() throws {
        try e2e24Fixture("microphone-priority", owner: "pending-lane-A")
        let settings = app.windows["VoiceBar QA Settings"]
        let order = settings.descendants(matching: .any)["microphone-priority-order"]
        let before = order.value as? String
        click(settings.buttons["Move microphone up"])
        step("2.4 microphone order changes") {
            XCTAssertNotNil(before)
            XCTAssertTrue(order.exists)
            XCTAssertNotNil(order.value as? String)
            XCTAssertNotEqual(order.value as? String, before)
        }
    }
    func testE2E24PermissionRevocation() throws {
        try e2e24Fixture("permission-revoked", owner: "pending-lane-A")
        let settings = app.windows["VoiceBar QA Settings"]
        click(settings.buttons["Check permissions"])
        step("2.4 revoked permission names its fix") {
            XCTAssertTrue(settings.staticTexts["permission-revoked"].exists)
            XCTAssertTrue(settings.buttons["permission-fix"].isHittable)
            XCTAssertEqual(settings.descendants(matching: .any).matching(identifier: "permission-revoked").count, 1)
        }
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
            // The fixture exposes retained take IDs here, not phase captions.
            let firstID = pill.descendants(matching: .any)["queued-take-1"].label
            let secondID = pill.descendants(matching: .any)["recording-take-2"].label
            XCTAssertFalse(firstID.isEmpty)
            XCTAssertFalse(secondID.isEmpty)
            XCTAssertTrue(firstID != secondID, "Queued and recording takes need distinct retained IDs")
        }
    }
    func e2e24HistoryScope(_ scope: String) throws {
        try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
        let pill = app.dialogs["VoiceBar QA Pill"]
        step("2.4 " + scope + " timestamp and day heading") {
            XCTAssertEqual(pill.staticTexts["history-day-header"].label, "Today")
            XCTAssertEqual(pill.staticTexts["history-timestamp"].label, "13:05")
        }
        click(pill.buttons["Copy"])
        step("2.4 copy writes selected text") { XCTAssertTrue(NSPasteboard.general.string(forType: .string) == "QA history " + scope, "Copy must return the controlled QA text") }
        try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
        let beforePaste = fixtureEvents().count
        click(pill.buttons["Paste"])
        step("2.4 paste reaches isolated sink with exact text") {
            XCTAssertEqual(Array(fixtureEvents().dropFirst(beforePaste)), ["history-paste:QA history " + scope])
        }
        if scope == "dictation" {
            try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
            click(pill.buttons["Details"])
            step("2.4 recording details open") { XCTAssertTrue(app.staticTexts["Recording details"].exists) }
            click(app.buttons["Close recording details"])
            try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
            click(pill.buttons["Re-transcribe"])
            step("2.4 retranscription starts") { XCTAssertTrue(pill.descendants(matching: .any)["queued-spinner"].exists) }
        }
        try e2e24Fixture("history-" + scope, owner: "pending-lane-A")
        click(pill.buttons["Play"])
        step("2.4 History playback becomes visible") { XCTAssertTrue(pill.buttons["Pause"].waitForExistence(timeout: 3)) }
    }

    func e2e24Tooltip(_ surface: String) throws {
            try e2e24Fixture("tooltips-" + surface, owner: "pending-lane-A")
            let root = surface == "settings" ? app.windows["VoiceBar QA Settings"] : app.dialogs["VoiceBar QA Pill"]
            let buttons = root.buttons.allElementsBoundByIndex.filter { $0.isHittable && !$0.identifier.hasPrefix("qa-fixture-") }
            step("2.4 " + surface + " has controls to hover") { XCTAssertFalse(buttons.isEmpty) }
            for button in buttons {
                step("2.4 hover " + button.identifier) {
                    XCTAssertFalse(button.identifier.isEmpty)
                    try mutate { button.hover() }
                    let tooltip = app.descendants(matching: .any)["tooltip-" + button.identifier]
                    XCTAssertTrue(tooltip.waitForExistence(timeout: 3))
                    XCTAssertFalse(tooltip.label.isEmpty)
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
    func e2e24Narration(_ operation: String) throws {
            try e2e24Fixture("narration-" + operation, owner: "pending-lane-B")
            step("2.4 " + operation + " uses the NarrationLayer audio and timing contract") {
                let pill = app.dialogs["VoiceBar QA Pill"]
                XCTAssertEqual(pill.staticTexts["narration-origin"].label, "NarrationLayer")
                XCTAssertTrue(pill.buttons["qa-word-2"].exists)
            }
    }
}
