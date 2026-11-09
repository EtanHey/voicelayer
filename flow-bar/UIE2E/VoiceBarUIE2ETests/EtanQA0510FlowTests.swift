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
    /// A fixed N row: a plain step (the product fix landed; its Swift proofs are in EtanQA0510Tests and
    /// NotchSurfaceHostedFlowTests). A failure here is a failure, not an expected one; the e2e24 case loop records
    /// the row's surface as verified when it passes.
    func qa0510Verified(_ row: String, _ body: () throws -> Void) {
        step(row + " Etan QA 0510", body)
    }
    /// Pulls down from the bare notch (the core above the pill's centre) by `distance`, as a user grabs it.
    func qa0510PullFromNotch(_ distance: CGFloat) throws {
        let start = CGPoint(x: qa0510Pill.frame.midX, y: qa0510Pill.frame.minY + 10)
        try qa0510Drag(start, CGPoint(x: start.x, y: start.y + distance)) {}
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }
    var qa0510Grip: XCUIElement { qa0510Pill.descendants(matching: .any)["notch-drawer-grip"] }
    /// A fixed row: a plain step on its exact e2e24 surface, never an expected failure.
    func qa0510Fixed(_ row: String, _ body: () throws -> Void) {
        step(row + " Etan QA 0510", surface: "e2e24:" + row, surfaces: ["e2e24:" + row], body)
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
            // Below the tab bar only: the band's own buttons (mic, History, gear) are not settings.
            let tabsBottom = qa0510Tabs.frame.maxY
            let controls = qa0510Pill.descendants(matching: .any).allElementsBoundByIndex.filter {
                [.checkBox, .popUpButton, .slider, .textField, .switch, .button, .disclosureTriangle, .cell]
                    .contains($0.elementType) && $0.frame.minY > tabsBottom
            }
            observations.append((title, handoffs.count, controls.count))
        }
        qa0510Verified("N1") {
            for (title, handoffs, controls) in observations {
                XCTAssertEqual(handoffs, 0, "[N1] \(title) still hands off to a window")
                XCTAssertGreaterThan(controls, 0, "[N1] \(title) has no settings control or History row in the drawer")
            }
        }
    }

    /// History pushes up by its handle and Settings by its grip (its panes scroll inside themselves); both follow
    /// the pointer and close on release at the top of the screen.
    func testN4BothDrawersTrackUpwardAndCloseOnRelease() throws {
        var observations: [(String, CGFloat, Bool)] = []
        for fixture in ["history-expanded", "tooltips-settings"] {
            try e2e24Fixture(fixture, owner: "lane-A")
            let isHistory = fixture == "history-expanded"
            let grip = isHistory ? qa0510Handle : qa0510Grip
            let marker = isHistory ? qa0510Handle : qa0510Pill.buttons["General"]
            try qa0510Require(grip)
            let before = grip.frame
            let from = qa0510Point(grip)
            var displacement: CGFloat = 0
            try qa0510Drag(from, CGPoint(x: from.x, y: 2)) {
                self.step("N4 in-flight " + fixture) { displacement = grip.exists ? grip.frame.minY - before.minY : -before.minY }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            step("N4 released " + fixture) { observations.append((fixture, displacement, marker.exists)) }
        }
        qa0510Verified("N4") {
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
        qa0510Verified("N5") {
            XCTAssertEqual(results.last ?? nil, "8 of 8 rows", "[N5] quick 0.01s grab must expand just like slow grab")
        }
    }

    func testN6SettingsPullHintDoesNotCoverHistoryRows() throws {
        try e2e24Fixture("history-expanded", owner: "lane-A")
        try qa0510Require(qa0510Handle)
        let from = CGPoint(x: qa0510Handle.frame.midX, y: qa0510Handle.frame.minY - 100)
        try qa0510Drag(from, CGPoint(x: from.x, y: from.y + 170)) {
            self.qa0510Verified("N6") {
                let hint = self.qa0510Pill.descendants(matching: .any)["notch-settings-pull-hint"]
                XCTAssertTrue(hint.exists, "[N6] the overpull still arms Settings and shows its hint")
                let rows = self.qa0510Pill.staticTexts.allElementsBoundByIndex.filter {
                    $0.isHittable && !$0.label.isEmpty && $0.label != "Release for Settings"
                }
                XCTAssertFalse(rows.isEmpty, "[N6] overpull must keep History rows visible")
                if hint.exists {
                    XCTAssertFalse(rows.contains { $0.frame.intersects(hint.frame) }, "[N6] Release for Settings overlaps a History row")
                }
            }
        }
        step("N6 release keeps the Settings transition") {
            XCTAssertTrue(self.qa0510Pill.buttons["General"].waitForExistence(timeout: 3))
        }
    }

    /// R3: History pulls down from the notch while recording, transcribing and on Typed (the recording band has no
    /// History button; its controls stay), and a longer pull lands on Settings.
    func testN7DrawersAreReachableInAllNonSpeechStates() throws {
        var observations: [(String, String, Bool)] = []
        for fixture in ["recording", "tooltips-transcribing", "typed-feedback"] {
            for (title, distance) in [("History", CGFloat(220)), ("Settings", CGFloat(470))] {
                try e2e24Fixture(fixture, owner: "lane-A")
                try qa0510Require(qa0510Pill)
                try qa0510PullFromNotch(distance)
                let marker = title == "History" ? qa0510Handle : qa0510Pill.buttons["General"]
                observations.append((fixture, title, marker.waitForExistence(timeout: 3)))
            }
        }
        qa0510Verified("N7") {
            for (fixture, title, opened) in observations {
                XCTAssertTrue(opened, "[N7] \(title) unreachable in \(fixture)")
            }
        }
    }

    /// R4: the same chevron in every allowed state with a left wing to spare (launcher, transcribing, Typed), and it
    /// opens General scrolled to Microphone priority in the notch. The recording wing is Etan's open Q2 (below).
    func testN9MicrophoneControlIsConsistentAcrossAllowedStates() throws {
        var observations: [(String, Bool, Bool)] = []
        for fixture in ["tooltips-launcher", "tooltips-transcribing", "typed-feedback"] {
            try e2e24Fixture(fixture, owner: "lane-A")
            try qa0510Require(qa0510Pill)
            let mic = qa0510Pill.buttons["Choose microphone"]
            var opened = false, atMicrophone = false
            if mic.exists && mic.isHittable {
                click(mic)
                opened = qa0510Pill.buttons["General"].waitForExistence(timeout: 3)
                // The requested scroll target, not merely the tab: the section header sits at the pane's top.
                let header = qa0510Pill.staticTexts["Microphone priority"]
                atMicrophone = opened && header.waitForExistence(timeout: 3) && header.isHittable
                    && header.frame.minY - qa0510Tabs.frame.maxY < 80
            }
            observations.append((fixture, opened, atMicrophone))
        }
        qa0510Verified("N9") {
            for (fixture, opened, atMicrophone) in observations {
                XCTAssertTrue(opened, "[N9] microphone control missing or not opening the notch setting in \(fixture)")
                XCTAssertTrue(atMicrophone, "[N9] \(fixture): the drawer is not scrolled to Microphone priority")
            }
        }
    }

    /// Etan's open Q2: the recording wing has no microphone control (pull-only, or a wider wing). Until he rules, the
    /// original N9 requirement for recording stays a visible strict expected failure, never a silent pass.
    func testQ2RecordingWingMicrophoneControlAwaitsEtan() throws {
        try e2e24Fixture("recording", owner: "lane-A")
        try qa0510Require(qa0510Pill)
        let mic = qa0510Pill.buttons["Choose microphone"]
        let hittable = mic.exists && mic.isHittable
        qa0510Expected(.qaQ2) {
            XCTAssertTrue(hittable, "[Q2] recording wing microphone control (Etan: pull-only or a wider wing)")
        }
    }

    func testN10RecordingWaveformSitsCloseToTimer() throws {
        try e2e24Fixture("recording", owner: "lane-A")
        let clock = qa0510Pill.descendants(matching: .any)["Recording time"]
        try qa0510Require(clock)
        let meter = qa0510Pill.descendants(matching: .any)["Input level"]
        try qa0510Require(meter)
        qa0510Verified("N10") {
            let gap = max(clock.frame.minX - meter.frame.maxX, meter.frame.minX - clock.frame.maxX)
            // The time's frame ends at its region's trailing edge; 2 pt of layout paints 4 pt of ink (EtanQA0510Tests).
            XCTAssertLessThanOrEqual(gap, 2, "[N10] waveform-to-time gap")
        }
    }

    func testT1QueueBackAndForwardSitBesidePause() throws {
        try qa0510Speaking()
        qa0510Fixed("T1") {
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
        qa0510Fixed("T2") { XCTAssertGreaterThan(handle.frame.minY, eye.frame.maxY, "[T2] handle must be under eye/replay") }
    }
    func testT4EyeAndReplayFormOneCentredGroup() throws {
        try e2e24Fixture("readback", owner: "lane-B")
        let eye = qa0510Pill.buttons["Hide teleprompter"], replay = qa0510Pill.buttons["Replay"]
        try qa0510Require(eye); try qa0510Require(replay)
        qa0510Fixed("T4") {
            XCTAssertEqual(eye.frame.midY, replay.frame.midY, accuracy: 1, "[T4] one row")
            XCTAssertEqual(eye.frame.union(replay.frame).midX, self.qa0510Pill.frame.midX, accuracy: 2,
                           "[T4] centre the pair independently of the terminal X")
        }
    }
    func testT5SpeakingWingHasAudioWaveformAndTime() throws {
        try qa0510Speaking()
        qa0510Fixed("T5") {
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
        qa0510Fixed("T6") { XCTAssertEqual(speed.frame.midY, pause.frame.midY, accuracy: 4, "[T6] speed belongs beside playback controls") }
    }
    func testT7StopMovesBesideEyeRow() throws {
        try qa0510Speaking()
        let stop = qa0510Pill.buttons["Stop speaking"], eye = qa0510Pill.buttons["Hide teleprompter"]
        try qa0510Require(stop); try qa0510Require(eye)
        qa0510Fixed("T7") { XCTAssertEqual(stop.frame.midY, eye.frame.midY, accuracy: 4, "[T7] move at least red Stop to eye row") }
    }
    func testT8ScrubberIsCloseToEyeReplayRow() throws {
        try qa0510Speaking()
        let scrub = qa0510Pill.descendants(matching: .any)["Playback position, agent speech"], eye = qa0510Pill.buttons["Hide teleprompter"]
        try qa0510Require(scrub); try qa0510Require(eye)
        qa0510Fixed("T8") {
            XCTAssertLessThanOrEqual(eye.frame.minY - scrub.frame.maxY, 7, "[T8] proposed 7 pt gap budget (existing stack spacing)")
        }
    }
}
