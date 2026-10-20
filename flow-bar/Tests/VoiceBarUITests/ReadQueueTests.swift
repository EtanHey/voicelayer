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

    func testSameOrEmptySelectionStopsAndClearsTheWholeQueue() {
        for second in ["Alpha selection", "  Alpha \n selection ", "", nil] as [String?] {
            let (state, a) = readingA()
            press(state, "Bravo selection")
            state.handleEvent(queueEvent(1, a))
            commands = []
            press(state, second)
            XCTAssertEqual(cmds, ["stop"], "same or empty selection is Stop: \(String(describing: second))")
            XCTAssertEqual(state.readQueueCount, 0)
            XCTAssertNil(VoiceBarPresentation.readQueueControl(for: state))
        }
        // Pressing again on the selection just queued is the same selection too.
        let (state, a) = readingA()
        press(state, "Bravo selection")
        state.handleEvent(queueEvent(1, a))
        commands = []
        press(state, "Bravo selection")
        XCTAssertEqual(cmds, ["stop"])
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

    func testNextOnTheLastItemStopsAndRetiresEveryIdentity() throws {
        let (state, a) = readingA()
        press(state, "Bravo selection")
        let b = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(speaking(id: b, text: "Bravo selection", read: "read-B"))
        state.handleEvent(queueEvent(0, b))
        let control = try XCTUnwrap(VoiceBarPresentation.readQueueControl(for: state))
        XCTAssertNil(control.countLabel, "the last item shows Next without a count")
        XCTAssertEqual(control.accessibilityLabel, "Stop reading")
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
        XCTAssertEqual(VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount, 2)
    }
}
