@testable import VoiceBarUI
import XCTest

/// QUEUE1 (Etan, 2026-10-20): Option+F5 on a different selection queues it; the pill shows "+N" and Next.
@MainActor
final class ReadQueueTests: XCTestCase {
    private var commands: [[String: Any]] = []

    /// Own selection A is playing, acknowledged by the daemon with its request id.
    private func readingA(_ text: String = "Alpha selection") -> (VoiceState, String) {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        commands = []
        state.sendCommand = { [unowned self] in commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text)) }
        state.speakSelection()
        let id = commands.last?["id"] as? String ?? ""
        state.handleEvent(speaking(id: id, text: text, read: "read-A"))
        commands = []
        return (state, id)
    }

    private func speaking(id: String, text: String, read: String, preparing: Bool = false) -> [String: Any] {
        ["type": "state", "state": "speaking", "text": preparing ? "Preparing speech…" : text, "request_id": id,
         "long_read": ["id": read, "preparing": preparing]]
    }

    private func press(_ state: VoiceState, _ text: String?) {
        state.selectionTextCaptureHandler = { $0(.completed(text)) }
        state.speakSelection()
    }

    private func queueEvent(_ count: Int, _ current: String?) -> [String: Any] {
        ["type": "read_queue", "count": count, "current_request_id": current ?? NSNull()]
    }

    private var cmds: [String] { commands.compactMap { $0["cmd"] as? String } }

    func testDifferentSelectionWhileSpeakingIsQueuedNotReplaced() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        XCTAssertEqual(cmds, ["speak_text"])
        XCTAssertEqual(commands.last?["queue"] as? Bool, true)
        XCTAssertEqual(commands.last?["text"] as? String, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        XCTAssertEqual(state.readQueueCount, 1)
        XCTAssertEqual(state.statusText, "Alpha selection", "the current read keeps playing")
        XCTAssertEqual(VoiceBarPresentation.readQueueControl(for: state)?.countLabel, "+1")
    }

    func testEmptySelectionStopsAndClearsTheWholeQueue() {
        for second in ["", nil] as [String?] {
            let (state, a) = readingA()
            press(state, "Bravo selection")
            state.handleEvent(queueEvent(1, a))
            commands = []
            press(state, second)
            XCTAssertEqual(cmds, ["stop"], "same or empty selection is Stop: \(String(describing: second))")
            XCTAssertEqual(state.readQueueCount, 0)
            XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        }
    }

    func testQueuedRepeatIsANoopWithAlreadyQueuedHint() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        commands = []
        press(state, "Bravo selection")
        XCTAssertTrue(cmds.isEmpty)
        XCTAssertEqual(state.readQueueCount, 1)
        XCTAssertEqual(state.selectionFeedbackNote, "Already queued")
    }

    func testPlayingRepeatAdvancesWithoutClearingPendingReads() {
        for text in ["Alpha selection", "  Alpha \n selection ", "1. Alpha selection", "- [x] Alpha selection"] {
            let (state, a) = readingA()
            press(state, "Bravo selection")
            press(state, "Charlie selection")
            state.handleEvent(queueEvent(2, a))
            commands = []
            press(state, text)
            XCTAssertEqual(cmds, ["read_next"], text)
            XCTAssertEqual(commands.last?["request_id"] as? String, a)
            XCTAssertEqual(state.readQueueCount, 2)
        }
    }

    func testEveryQueuedIdentityIsCheckedBeforeCapacityAndKeepsCaseAndTimerChanges() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        press(state, "Charlie selection")
        state.handleEvent(queueEvent(10, a))
        for text in ["* [ ] Bravo selection", "2. Charlie selection"] {
            commands = []
            press(state, text)
            XCTAssertTrue(cmds.isEmpty)
            XCTAssertEqual(state.selectionFeedbackNote, "Already queued")
        }
        state.handleEvent(queueEvent(2, a))
        commands = []
        press(state, "bravo selection")
        press(state, "Timer 4m 01s")
        press(state, "Timer 4m 03s")
        XCTAssertEqual(cmds, ["speak_text", "speak_text", "speak_text"])
    }

    func testSharedSelectionIdentityFixtures() throws {
        struct Fixture: Decodable { let name: String, input: String, identity: String }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let rows = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("formal/speech-queue/selection-identity.json")))
        for row in rows {
            XCTAssertEqual(Array(SelectionAdmission.identity(row.input).utf8), Array(row.identity.utf8), row.name)
        }
    }

    func testCanonicalEquivalentSelectionsStopThePlayingReadAndHintForQueuedRead() {
        for (composed, decomposed) in [("café", "cafe\u{0301}"), ("ש\u{05b8}\u{05c1}", "ש\u{05c1}\u{05b8}")] {
            let (playing, _) = readingA(composed)
            press(playing, decomposed)
            XCTAssertEqual(cmds, ["stop"])
            let (queued, a) = readingA()
            press(queued, composed)
            queued.handleEvent(queueEvent(1, a))
            commands = []
            press(queued, decomposed)
            XCTAssertTrue(cmds.isEmpty)
            XCTAssertEqual(queued.selectionFeedbackNote, "Already queued")
        }
    }

    func testExternalPreemptionDropsDaemonMembershipButPreservesANewInflightRequest() throws {
        for selected in ["Bravo selection", "Charlie selection"] {
            let (state, a) = readingA()
            for text in ["Bravo selection", "Charlie selection"] {
                press(state, text)
                let id = try XCTUnwrap(commands.last?["id"] as? String)
                state.handleEvent(["type": "ack", "command": "speak_text", "id": id, "outcome": "accept", "reason": "queued"])
            }
            state.handleEvent(queueEvent(2, a))
            state.handleEvent(queueEvent(0, nil))
            state.handleEvent(speaking(id: "external", text: "Agent speech", read: "external-read"))
            commands = []
            press(state, selected)
            XCTAssertEqual(cmds, ["speak_text"], selected)
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            commands = []
            press(state, selected == "Bravo selection" ? "Charlie selection" : "Bravo selection")
            XCTAssertEqual(cmds, ["speak_text"])
        }
        let (state, _) = readingA()
        press(state, "Inflight selection")
        let inflight = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(queueEvent(0, nil))
        state.handleEvent(speaking(id: inflight, text: "Projected display", read: "inflight-read"))
        commands = []
        press(state, "Inflight selection")
        XCTAssertEqual(cmds, ["stop"], "a genuine unacknowledged submission still binds its receipt")
    }

    func testClearedSnapshotAlreadyOverridesTheOldPlayingDisplayBeforeExternalSpeechArrives() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(["type": "ack", "command": "speak_text", "id": commands.last?["id"] as? String ?? "", "outcome": "accept", "reason": "queued"])
        state.handleEvent(queueEvent(1, a))
        state.handleEvent(queueEvent(0, nil))
        commands = []
        press(state, "Alpha selection")
        XCTAssertEqual(cmds, ["speak_text"])
    }

    func testSameTextAfterPausedReadWasParkedForDictationStartsFresh() {
        let (state, a) = readingA()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Alpha selection", "request_id": a,
                           "long_read": ["id": "read-A"], "playback_id": "p-A", "generation": 1])
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-A", "generation": 2,
                           "offset_ms": 500, "chunk_offset_ms": 500])
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        state.mode = .idle
        commands = []
        press(state, "Alpha selection")
        XCTAssertEqual(cmds, ["speak_text"])
    }

    func testModelAdmissionCasesDriveRealVoiceState() throws {
        struct Row: Decodable {
            let playing: Int, pending: [Int], suspended: Bool, selected: Int, event: String, decision: String, preempted: Bool
        }
        guard let path = ProcessInfo.processInfo.environment["VOICELAYER_ADMISSION_CASES"] else {
            throw XCTSkip("Run formal/speech-queue/check.sh for TLC admission cases")
        }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for row in rows {
            for marker in ["", "1. ", "- [x] ", "* [ ] "] {
                let state = VoiceState()
                state.isConnected = true
                state.sendCommand = { [unowned self] in commands.append($0) }
                let text = { (n: Int) in "Item \(n)" }
                var owner = ""
                if row.playing != 0 {
                    press(state, text(row.playing))
                    owner = try XCTUnwrap(commands.last?["id"] as? String)
                    state.handleEvent(speaking(id: owner, text: "Projected display", read: "model-read"))
                }
                for item in row.pending {
                    press(state, text(item))
                    let id = try XCTUnwrap(commands.last?["id"] as? String)
                    state.handleEvent(["type": "ack", "command": "speak_text", "id": id, "outcome": "accept", "reason": "queued"])
                }
                if !row.pending.isEmpty { state.handleEvent(queueEvent(row.pending.count, owner)) }
                if row.suspended {
                    state.retainingReadQueueOnStop { state.stop() }
                    state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                    state.mode = .idle
                }
                if row.preempted {
                    state.handleEvent(queueEvent(0, nil))
                    state.handleEvent(speaking(id: "external", text: "Agent speech", read: "external-read"))
                    state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
                    state.mode = .idle
                }
                commands = []
                if row.event == "stop" { state.stop(); state.handleEvent(queueEvent(0, nil)) }
                else if row.event == "f5" { state.retainingReadQueueOnStop { state.stop() } }
                else { press(state, marker + text(row.selected)) }
                let label = "p=\(row.playing) q=\(row.pending) suspended=\(row.suspended) event=\(row.event) input=\(marker)\(row.selected)"
                XCTAssertEqual(cmds, row.decision == "hint" ? [] : [row.decision], label)
                if row.decision == "speak_text" {
                    XCTAssertEqual(commands.last?["source"] as? String, "selection", label)
                    XCTAssertEqual(commands.last?["queue"] as? Bool == true, row.playing != 0 && !row.preempted, label)
                }
                if row.decision == "hint" { XCTAssertEqual(state.selectionFeedbackNote, "Already queued", label) }
                if row.decision == "read_next" { XCTAssertEqual(commands.last?["request_id"] as? String, owner, label) }
                if row.event == "stop" { XCTAssertEqual(state.readQueueCount, 0, label) }
                else { XCTAssertEqual(state.readQueueCount, row.preempted ? 0 : row.pending.count, label) }
                if row.event == "f5", !row.pending.isEmpty { XCTAssertEqual(commands.last?["retain_read_queue"] as? Bool, true, label) }
            }
        }
        print("Replayed \(rows.count * 4) TLC cases through real VoiceState capture completion and commands")
    }

    func testNextSkipsToTheFollowingReadAndIgnoresTheSkippedReadsLateReceipts() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        press(state, "Charlie selection")
        state.handleEvent(queueEvent(2, a))
        commands = []
        state.skipToNextRead()
        XCTAssertEqual(cmds, ["read_next"])
        XCTAssertEqual(commands.last?["request_id"] as? String, a)
        // A stale chunk receipt from the skipped read never comes back.
        state.handleEvent(speaking(id: a, text: "Alpha late chunk", read: "read-A"))
        XCTAssertNotEqual(state.statusText, "Alpha late chunk")
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        state.handleEvent(queueEvent(1, b))
        XCTAssertEqual(state.statusText, "Bravo selection")
        XCTAssertEqual(state.readQueueCount, 1)
        XCTAssertEqual(VoiceBarPresentation.readQueueControl(for: state)?.countLabel, "+1")
    }

    func testTheLastItemHidesNextAndAStaleNextStillStopsAndRetiresEveryIdentity() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        state.handleEvent(queueEvent(0, b))
        // PILL1: nothing waits behind the last item, so the pill offers no Next.
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state), "the last item shows no Next")
        // The command API stays defensive: a Next that still arrives stops and retires the identities.
        commands = []
        state.skipToNextRead()
        XCTAssertEqual(cmds, ["read_next"])
        XCTAssertEqual(commands.last?["request_id"] as? String, b)
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        state.handleEvent(speaking(id: b, text: "Bravo late chunk", read: "read-B"))
        XCTAssertNotEqual(state.statusText, "Bravo late chunk")
        _ = a
    }

    func testPausedReadStaysPausedWhenANewSelectionQueues() {
        let (state, a) = readingA()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Alpha selection", "request_id": a,
                           "long_read": ["id": "read-A"], "playback_id": "p-A", "generation": 1])
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-A", "generation": 2,
                           "offset_ms": 500, "chunk_offset_ms": 500])
        XCTAssertTrue(state.isPlaybackPaused)
        commands = []
        press(state, "Bravo selection")
        XCTAssertEqual(cmds, ["speak_text"])
        XCTAssertEqual(commands.last?["queue"] as? Bool, true)
        state.handleEvent(queueEvent(1, a))
        XCTAssertTrue(state.isPlaybackPaused, "the current read stays paused")
        XCTAssertEqual(VoiceBarPresentation.readQueueControl(for: state)?.countLabel, "+1")
    }

    func testRecordingRejectsOptionF5WithTheBusyNoteAndQueuesNothing() {
        let (state, a) = readingA()
        state.handleEvent(queueEvent(0, nil))
        state.mode = .recording
        commands = []
        state.selectionTextCaptureHandler = { _ in XCTFail("busy must not capture") }
        state.speakSelection()
        XCTAssertTrue(state.showsSelectionBusyNote)
        XCTAssertEqual(commands.count, 0)
        XCTAssertEqual(state.readQueueCount, 0)
        _ = a
    }

    func testAFullQueueShowsQueueFullAndSendsNothing() throws {
        let (state, a) = readingA()
        state.handleEvent(queueEvent(10, a))
        press(state, "Eleventh selection")
        XCTAssertEqual(commands.count, 0)
        XCTAssertEqual(state.selectionFeedbackNote, "Queue full")
        // The daemon's own bound reports through the same note.
        let (other, otherA) = readingA()
        press(other, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        other.handleEvent(["type": "ack", "command": "speak_text", "id": b, "outcome": "reject", "reason": "queue full"])
        XCTAssertEqual(other.selectionFeedbackNote, "Queue full")
        XCTAssertEqual(other.statusText, "Alpha selection")
        _ = otherA
    }

    func testStopAndDisconnectClearTheQueueAndAStaleQueuedReceiptNeverStarts() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(queueEvent(1, a))
        state.stop()
        XCTAssertEqual(state.readQueueCount, 0)
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B", preparing: true))
        XCTAssertNotEqual(state.statusText, "Preparing speech…", "a removed item's late receipt is stale")

        let (other, otherA) = readingA()
        other.handleEvent(queueEvent(2, otherA))
        other.mode = .disconnected
        XCTAssertEqual(other.readQueueCount, 0)
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: other))
    }

    func testNextControlStylingAndTheLeadingWingGrowsForNextAndCount() throws {
        let (state, a) = readingA()
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state), "no queue, no Next")
        state.handleEvent(queueEvent(2, a))
        let control = try XCTUnwrap(VoiceBarPresentation.readQueueControl(for: state))
        XCTAssertEqual(control.iconName, "forward.fill")
        XCTAssertEqual(control.countLabel, "+2")
        XCTAssertEqual(control.accessibilityLabel, "Next read")
        XCTAssertEqual(control.leadingSlotCount, 3)
        let material = VoiceBarNotchContract.material
        let wing = VoiceBarNotchContract.compactContentFitWingWidth(
            contentWidth: 3 * material.compactControlSize + 2 * material.compactControlSpacing)
        XCTAssertEqual(VoiceBarPresentation.playbackLeadingWingWidth(slotCount: control.leadingSlotCount), wing)
        XCTAssertEqual(VoiceBarPresentation.playbackLeadingWingWidth(slotCount: 1),
                       VoiceBarNotchContract.compactIndicatorLaneWidth, "P16's single pause lane is unchanged")
        let input = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true,
                                                  readQueueLeadingSlotCount: control.leadingSlotCount)
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).geometry.leadingWingWidth, wing)
        state.handleEvent(queueEvent(0, a))
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state), "count 0 removes Next and its slot")
    }

    /// PILL1: one waiting read shows Next with "+1" in three slots; when it drains to zero, Next and its slot go
    /// and the wing returns to the single pause lane. An F5-suspended idle queue keeps Next reachable.
    func testNextAppearsOnlyWhileAReadWaitsAndTheSuspendedQueueStaysReachable() throws {
        let (state, a) = readingA()
        state.handleEvent(queueEvent(1, a))
        let one = try XCTUnwrap(VoiceBarPresentation.readQueueControl(for: state))
        XCTAssertEqual(one.countLabel, "+1")
        XCTAssertEqual(one.accessibilityLabel, "Next read")
        XCTAssertEqual(one.leadingSlotCount, 3)

        state.handleEvent(queueEvent(0, a))
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        let slots = VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1
        let input = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true,
                                                  readQueueLeadingSlotCount: slots)
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).geometry.leadingWingWidth,
                       VoiceBarNotchContract.compactIndicatorLaneWidth, "no empty Next slot remains")
        XCTAssertNil(VoiceBarPresentation.readQueueControl(
            mode: .speaking, isReadback: false, currentRequestID: a, count: -1), "negative counts are zero")

        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        state.retainingReadQueueOnStop { state.stop() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.mode = .idle
        let suspended = try XCTUnwrap(VoiceBarPresentation.readQueueControl(for: state))
        XCTAssertEqual(suspended.countLabel, "+1")
        XCTAssertEqual(suspended.leadingSlotCount, 2, "Next and +1, no pause")
        commands = []
        state.skipToNextRead()
        XCTAssertEqual(cmds, ["read_next"])
    }

    // MARK: - R2 D2 (lead ruling a): F5 over a playing read keeps the queued reads for Next

    func testF5StopOverAPlayingReadKeepsTheQueueAndNextResumesItAfterTheCapture() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        press(state, "Charlie selection")
        state.handleEvent(queueEvent(2, a))
        commands = []
        state.retainingReadQueueOnStop { state.stop() }
        XCTAssertEqual(cmds, ["stop"], "the read still stops exactly as today")
        XCTAssertEqual(commands.last?["retain_read_queue"] as? Bool, true)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        // The dictation runs and ends; nothing plays and the queue is still there.
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state), "no Next while recording")
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        state.mode = .idle
        XCTAssertEqual(state.readQueueCount, 2)
        let control = try XCTUnwrap(VoiceBarPresentation.readQueueControl(for: state))
        XCTAssertEqual(control.countLabel, "+2")
        XCTAssertEqual(control.leadingSlotCount, 2, "Next and +2, no pause")
        state.isCollapsed = true
        let idle = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: .idle, readQueueLeadingSlotCount: control.leadingSlotCount, isCollapsed: true))
        XCTAssertEqual(idle.visualState, .compactStatus, "the waiting queue keeps the pill open")
        XCTAssertEqual(idle.geometry.leadingWingWidth, VoiceBarPresentation.playbackLeadingWingWidth(slotCount: 2))
        commands = []
        state.skipToNextRead()
        XCTAssertEqual(cmds, ["read_next"])
        XCTAssertEqual(commands.last?["request_id"] as? String, a)
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "Bravo selection", "the queued read's identity survived the F5 stop")
    }

    func testStopButtonOutsideTheF5ScopeStillClearsEverything() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        commands = []
        state.stop()
        XCTAssertNil(commands.last?["retain_read_queue"])
        XCTAssertEqual(state.readQueueCount, 0)
    }

    func testEmptyOptionF5WhileReadsWaitClearsThemLikeStop() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        state.retainingReadQueueOnStop { state.stop() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        commands = []
        press(state, "")
        XCTAssertEqual(cmds, ["stop"])
        XCTAssertNil(commands.last?["retain_read_queue"])
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
    }

    // MARK: - QUEUE1b SOL-R2-1: the retained queue survives the capture's own stop/cancel

    func testCaptureReleaseOrCancelKeepsTheRetainedQueueAndBStillBinds() throws {
        for end in ["release", "cancel"] {
            let (state, a) = readingA()
            press(state, "Bravo selection")
            let b = try XCTUnwrap(commands.last?["id"] as? String)
            state.handleEvent(queueEvent(1, a))
            state.retainingReadQueueOnStop { state.stop() }
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            state.record(pressToTalk: true)
            state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
            XCTAssertEqual(state.mode, .recording)
            commands = []
            if end == "release" { state.stop(physicalPress: true) } else { state.cancel() }
            XCTAssertEqual(cmds, [end == "release" ? "stop" : "cancel"], "capture mechanics unchanged")
            XCTAssertNil(commands.last?["retain_read_queue"])
            state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
            state.mode = .idle
            XCTAssertEqual(state.readQueueCount, 1, end)
            XCTAssertEqual(VoiceBarPresentation.readQueueControl(for: state)?.countLabel, "+1", end)
            commands = []
            state.skipToNextRead()
            XCTAssertEqual(commands.last?["request_id"] as? String, a, end)
            state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
            XCTAssertEqual(state.statusText, "Bravo selection", "\(end): B's receipt still binds")
        }
    }

    // MARK: - QUEUE1b Q1B-SOL-1 (lead ruling): Hide ends the read chain on both sides

    func testHideDuringTheCaptureDiscardsTheRetainedQueueOnBothSides() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(queueEvent(1, a))
        state.retainingReadQueueOnStop { state.stop() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.record(pressToTalk: true)
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        commands = []
        state.snooze()
        XCTAssertEqual(cmds, ["cancel"], "capture mechanics unchanged: Hide still cancels the dictation")
        XCTAssertEqual(commands.last?["discard_read_queue"] as? Bool, true, "the daemon is told to drop the queue")
        XCTAssertEqual(state.readQueueCount, 0)
        state.unsnooze()
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        state.mode = .idle
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        commands = []
        state.skipToNextRead()
        XCTAssertEqual(commands.count, 0, "no Next survives Hide")
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        XCTAssertNotEqual(state.statusText, "Bravo selection", "B is forgotten")
    }

    func testHideWhileReadsWaitInIdleTellsTheDaemonToDropThem() {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        state.retainingReadQueueOnStop { state.stop() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        commands = []
        state.snooze()
        XCTAssertEqual(cmds, ["stop"])
        XCTAssertNil(commands.last?["retain_read_queue"])
        XCTAssertEqual(state.readQueueCount, 0)
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
    }

    // MARK: - QUEUE1c (lead ruling): an idle Cancel ends the waiting chain on both sides

    /// Sol's `testReviewIdleCancelMustNotOrphanWaitingReads`, adapted to the ruling: the idle Cancel
    /// (voicebar://cancel, socket-control) discards the waiting reads instead of orphaning them in the daemon.
    func testReviewIdleCancelMustNotOrphanWaitingReads() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(queueEvent(1, a))
        state.retainingReadQueueOnStop { state.stop() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.mode = .idle
        commands = []
        state.cancel() // voicebar://cancel and socket-control cancel are unguarded
        XCTAssertEqual(cmds, ["cancel"])
        XCTAssertEqual(state.readQueueCount, 0, "the mirror clears with the identities")
        XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        commands = []
        state.skipToNextRead()
        XCTAssertTrue(commands.isEmpty, "no Next survives an idle Cancel")
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        XCTAssertNotEqual(state.statusText, "Bravo selection", "B is retired")
    }
}
