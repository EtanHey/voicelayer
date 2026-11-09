import AppKit
import XCTest

/// Synthetic UI only. All fixture, render and input preconditions are OUTSIDE the XFAIL matcher.
extension VoiceBarFlowTests {
    var qa0510Pill: XCUIElement { app.dialogs["VoiceBar QA Pill"] }
    var qa0510Tabs: XCUIElement { qa0510Pill.groups["Settings tabs"] }
    var qa0510Handle: XCUIElement { qa0510Pill.descendants(matching: .any)["notch-history-extend-handle"] }

    func qa0510Require(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 4), !element.frame.isEmpty else {
            XCTFail("0510 fixture unavailable: " + element.identifier)
            throw NSError(domain: "0510 fixture unavailable", code: 1)
        }
    }
    func qa0510Expected(_ row: UIE2EKnownIssue, _ body: () throws -> Void) {
        step(row.rawValue + " Etan QA 0510", expected: row,
             surface: "e2e24:" + row.rawValue, surfaces: ["e2e24:" + row.rawValue], body)
    }
    func qa0510Speaking() throws {
        try e2e24Fixture("speaking", owner: "lane-B")
        try qa0510Require(qa0510Pill.buttons["Pause"])
        try qa0510Require(qa0510Pill.buttons["qa-word-2"])
    }
    func qa0510Point(_ element: XCUIElement) -> CGPoint { CGPoint(x: element.frame.midX, y: element.frame.midY) }

    /// Hold the real pointer while the broker captures the in-flight geometry. Always release it on error.
    func qa0510Drag(_ from: CGPoint, _ to: CGPoint, held: () throws -> Void) throws {
        func post(_ type: CGEventType, _ point: CGPoint) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .left))
            try mutate { event.post(tap: .cghidEventTap) }
        }
        guard CGPreflightPostEventAccess() else {
            throw XCTSkip("N4/N6 pointer injection permission unavailable; not a product failure")
        }
        try post(.mouseMoved, from)
        try post(.leftMouseDown, from)
        // Revoke only this helper's already-owned press even if a later boundary latches STOP.
        // This is cleanup, never another click/drag; routing it through mutate could leave a button held.
        let release = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                           mouseCursorPosition: to, mouseButton: .left))
        defer { release.post(tap: .cghidEventTap) }
        for i in 1...8 {
            let t = CGFloat(i) / 8
            try post(.leftMouseDragged, CGPoint(x: from.x + (to.x-from.x)*t, y: from.y + (to.y-from.y)*t))
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try held()
    }

    func testN1SettingsContainControlsInsteadOfWindowHandoffs() throws {
        var observations: [(String, Int, Int)] = []
        for title in ["General", "Transcription", "Dictionary", "Speech", "History"] {
            try e2e24Fixture("tooltips-settings", owner: "lane-A")
            try qa0510Require(qa0510Tabs.buttons[title])
            click(qa0510Tabs.buttons[title])
            let handoffs = qa0510Pill.buttons.allElementsBoundByIndex.filter {
                $0.label == "All settings…" || $0.label.hasPrefix("Open ") && $0.label.hasSuffix(" settings")
            }
            let controls = qa0510Pill.descendants(matching: .any).allElementsBoundByIndex.filter {
                [.checkBox, .popUpButton, .slider, .textField, .switch].contains($0.elementType)
            }
            observations.append((title, handoffs.count, controls.count))
        }
        qa0510Expected(.qaN1) {
            for (title, handoffs, controls) in observations {
                XCTAssertEqual(handoffs, 0, "[N1] \(title) still hands off to a window")
                XCTAssertGreaterThan(controls, 0, "[N1] \(title) has no editable settings control")
            }
        }
    }

    func testN4BothDrawersTrackUpwardAndCloseOnRelease() throws {
        var observations: [(String, CGFloat, Bool)] = []
        for fixture in ["history-expanded", "tooltips-settings"] {
            try e2e24Fixture(fixture, owner: "lane-A")
            let isHistory = fixture == "history-expanded"
            let marker = isHistory ? qa0510Handle : qa0510Pill.buttons["General"]
            try qa0510Require(marker)
            let before = marker.frame
            let from = isHistory ? qa0510Point(marker) : CGPoint(x: before.midX, y: before.maxY + 110)
            let to = CGPoint(x: from.x, y: 2)
            var displacement: CGFloat = 0
            try qa0510Drag(from, to) {
                self.step("N4 in-flight " + fixture) { displacement = marker.exists ? marker.frame.minY - before.minY : 0 }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            step("N4 released " + fixture) { observations.append((fixture, displacement, marker.exists)) }
        }
        qa0510Expected(.qaN4) {
            for (fixture, displacement, remains) in observations {
                XCTAssertLessThan(displacement, -10, "[N4] \(fixture) must follow pointer before release")
                XCTAssertFalse(remains, "[N4] \(fixture) stays open after release at the top")
            }
        }
    }

    func testN5QuickHandleGrabMatchesSlowGrab() throws {
        var results: [String?] = []
        for hold in [0.3, 0.01] {
            try e2e24Fixture("history-20", owner: "lane-A")
            try qa0510Require(qa0510Handle)
            XCTAssertEqual(qa0510Handle.value as? String, "6 of 8 rows", "fixture starts collapsed")
            let start = qa0510Handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            step("N5 handle grab \(hold)s") {
                try self.mutate { start.press(forDuration: hold, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)),
                                             withVelocity: .fast, thenHoldForDuration: 0) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                results.append(self.qa0510Handle.value as? String)
            }
        }
        XCTAssertEqual(results.first ?? nil, "8 of 8 rows", "fixture: slow grab is the positive control")
        qa0510Expected(.qaN5) {
            XCTAssertEqual(results.last ?? nil, "8 of 8 rows", "[N5] quick 0.01s grab must expand just like slow grab")
        }
    }

    func testN6SettingsPullHintDoesNotCoverHistoryRows() throws {
        try e2e24Fixture("history-expanded", owner: "lane-A")
        try qa0510Require(qa0510Handle)
        let from = CGPoint(x: qa0510Handle.frame.midX, y: qa0510Handle.frame.minY - 100)
        try qa0510Drag(from, CGPoint(x: from.x, y: from.y + 170)) {
            self.qa0510Expected(.qaN6) {
                let grip = self.qa0510Handle.frame
                // The production 24 pt hint plus its 6 pt bottom inset, immediately above the 18 pt grip band.
                let hint = CGRect(x: grip.midX - 80, y: grip.minY - 30, width: 160, height: 24)
                let rows = self.qa0510Pill.staticTexts.allElementsBoundByIndex.filter {
                    $0.isHittable && !$0.label.isEmpty && $0.label != "Release for Settings"
                }
                XCTAssertFalse(rows.isEmpty, "[N6] overpull must keep History rows visible")
                XCTAssertFalse(rows.contains { $0.frame.intersects(hint) }, "[N6] Release for Settings overlaps a History row")
            }
        }
        step("N6 release keeps the Settings transition") {
            XCTAssertTrue(self.qa0510Pill.buttons["General"].waitForExistence(timeout: 3))
        }
    }

    func testN7DrawersAreReachableInAllNonSpeechStates() throws {
        var observations: [(String, String, Bool)] = []
        for fixture in ["recording", "tooltips-transcribing", "typed-feedback"] {
            for title in ["History", "Settings"] {
                try e2e24Fixture(fixture, owner: "lane-A")
                try qa0510Require(qa0510Pill)
                let button = qa0510Pill.buttons[title]
                var opened = false
                if button.exists && button.isHittable {
                    click(button)
                    let marker = title == "History" ? qa0510Handle : qa0510Pill.buttons["General"]
                    opened = marker.waitForExistence(timeout: 3)
                }
                observations.append((fixture, title, opened))
            }
        }
        qa0510Expected(.qaN7) {
            for (fixture, title, opened) in observations {
                XCTAssertTrue(opened, "[N7] \(title) unreachable in \(fixture)")
            }
        }
    }

    func testN9MicrophoneControlIsConsistentAcrossAllowedStates() throws {
        var observations: [(String, Bool)] = []
        for fixture in ["tooltips-launcher", "recording", "tooltips-transcribing", "typed-feedback"] {
            try e2e24Fixture(fixture, owner: "lane-A")
            try qa0510Require(qa0510Pill)
            let mic = qa0510Pill.buttons["Choose microphone"]
            observations.append((fixture, mic.exists && mic.isHittable))
        }
        qa0510Expected(.qaN9) {
            for (fixture, hittable) in observations {
                XCTAssertTrue(hittable, "[N9] microphone dropdown missing in \(fixture)")
            }
        }
        try e2e24Fixture("tooltips-launcher", owner: "lane-A")
        try qa0510Require(qa0510Pill.buttons["Choose microphone"])
        click(qa0510Pill.buttons["Choose microphone"])
        step("N9 microphone route is a notch dropdown or notch settings") {
            XCTAssertTrue(self.app.menuItems["Default: QA microphone A"].exists || self.qa0510Pill.buttons["General"].exists)
        }
    }

    func testN10RecordingWaveformSitsCloseToTimer() throws {
        try e2e24Fixture("recording", owner: "lane-A")
        let clock = qa0510Pill.descendants(matching: .any)["Recording time"]
        guard clock.exists else { throw XCTSkip("N10 depends on integration/2.3 recording time; absent from 2.4 base") }
        let meter = qa0510Pill.descendants(matching: .any)["Input level"]
        try qa0510Require(meter)
        qa0510Expected(.qaN10) {
            let gap = max(clock.frame.minX - meter.frame.maxX, meter.frame.minX - clock.frame.maxX)
            XCTAssertLessThanOrEqual(gap, 4, "[N10] waveform-to-time gap; 4 pt is the candidate meterGap budget")
        }
    }

    func testT1QueueBackAndForwardSitBesidePause() throws {
        try qa0510Speaking()
        qa0510Expected(.qaT1) {
            let back = self.qa0510Pill.buttons["Previous read"]
            let forward = self.qa0510Pill.buttons["Next read"]
            XCTAssertTrue(back.exists && forward.exists, "[T1] both queue directions must be represented")
            if back.exists { XCTAssertFalse(back.isEnabled, "[T1] no previous queued item means disabled Back") }
            if forward.exists { XCTAssertFalse(forward.isEnabled, "[T1] no next queued item means disabled Forward") }
            if back.exists { XCTAssertEqual(back.frame.midY, self.qa0510Pill.buttons["Pause"].frame.midY, accuracy: 4, "[T1] Back beside Pause") }
        }
    }
    func testT2HeightHandleIsBelowEyeReplayRow() throws {
        try qa0510Speaking()
        let handle = qa0510Pill.descendants(matching: .any)["Teleprompter height"]
        let eye = qa0510Pill.buttons["Hide teleprompter"]
        try qa0510Require(handle); try qa0510Require(eye)
        qa0510Expected(.qaT2) { XCTAssertGreaterThan(handle.frame.minY, eye.frame.maxY, "[T2] handle must be under eye/replay") }
    }
    func testT4EyeAndReplayFormOneCentredGroup() throws {
        try e2e24Fixture("readback", owner: "lane-B")
        let eye = qa0510Pill.buttons["Hide teleprompter"], replay = qa0510Pill.buttons["Replay"]
        try qa0510Require(eye); try qa0510Require(replay)
        qa0510Expected(.qaT4) {
            XCTAssertEqual(eye.frame.midY, replay.frame.midY, accuracy: 1, "[T4] one row")
            XCTAssertEqual(eye.frame.union(replay.frame).midX, self.qa0510Pill.frame.midX, accuracy: 2,
                           "[T4] centre the pair independently of the terminal X")
        }
    }
    func testT5SpeakingWingHasAudioWaveformAndTime() throws {
        try qa0510Speaking()
        qa0510Expected(.qaT5) {
            let waveform = self.qa0510Pill.descendants(matching: .any)["Input level"]
            XCTAssertTrue(waveform.exists, "[T5] speech waveform missing")
            if waveform.exists { XCTAssertEqual(waveform.frame.midY, self.qa0510Pill.descendants(matching: .any)["Reading time"].frame.midY,
                           accuracy: 4, "[T5] waveform beside time") }
        }
    }
    func testT6SpeedIsInTopPlaybackRow() throws {
        try qa0510Speaking()
        let speed = qa0510Pill.buttons["Playback speed"], pause = qa0510Pill.buttons["Pause"]
        try qa0510Require(speed)
        qa0510Expected(.qaT6) { XCTAssertEqual(speed.frame.midY, pause.frame.midY, accuracy: 4, "[T6] speed belongs beside playback controls") }
    }
    func testT7StopMovesBesideEyeRow() throws {
        try qa0510Speaking()
        let stop = qa0510Pill.buttons["Stop speaking"], eye = qa0510Pill.buttons["Hide teleprompter"]
        try qa0510Require(stop); try qa0510Require(eye)
        qa0510Expected(.qaT7) { XCTAssertEqual(stop.frame.midY, eye.frame.midY, accuracy: 4, "[T7] move at least red Stop to eye row") }
    }
    func testT8ScrubberIsCloseToEyeReplayRow() throws {
        try qa0510Speaking()
        let scrub = qa0510Pill.descendants(matching: .any)["Playback position, agent speech"], eye = qa0510Pill.buttons["Hide teleprompter"]
        try qa0510Require(scrub); try qa0510Require(eye)
        qa0510Expected(.qaT8) {
            XCTAssertLessThanOrEqual(eye.frame.minY - scrub.frame.maxY, 7, "[T8] proposed 7 pt gap budget (existing stack spacing)")
        }
    }
}
