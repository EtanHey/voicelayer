@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// P16 R2 (Sol S1): a paused read is silent, so F5 must record over it, never Stop it.
final class PausedPlaybackRoutingTests: XCTestCase {
    private func pausedState() -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.frontmostAppProvider = { nil }
        state.isConnected = true
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent([
            "type": "state", "state": "speaking", "text": "Parked read", "playback_id": "playback-9", "generation": 1,
        ])
        state.handleEvent([
            "type": "playback_state", "state": "paused", "playback_id": "playback-9", "generation": 2,
            "offset_ms": 1500, "chunk_offset_ms": 1500,
        ])
        XCTAssertTrue(state.isPlaybackPaused)
        return (state, { sent })
    }

    /// The production gesture machine wired exactly as AppDelegate wires it.
    func testPauseThenF5HoldRecordsAndReleaseStopsOnlyTheCapture() {
        let (state, sent) = pausedState()
        let gesture = GestureStateMachine()
        var now: TimeInterval = 100
        var scheduled: [(Int, DispatchWorkItem)] = []
        gesture.clock = { now }
        gesture.schedule = { scheduled.append(($0, $1)) }
        let router = VoiceBarCommandRouter(voiceState: state, resetHotkeyState: { gesture.reset() })
        gesture.onHoldStart = { router.handleHotkeyHoldStart() }
        gesture.onHoldEnd = { router.handleHotkeyHoldEnd(holdDuration: 1.2) }
        gesture.onSingleTap = { router.handleHotkeySingleTap() }

        gesture.handleKeyDown()
        XCTAssertEqual(scheduled.map { $0.0 }, [GestureStateMachine.holdThresholdMs])
        XCTAssertTrue(sent().isEmpty, "recording waits for the hold threshold")
        now += Double(GestureStateMachine.holdThresholdMs) / 1000
        scheduled.removeFirst().1.perform()
        XCTAssertEqual(sent().map { $0["cmd"] as? String }, ["record"], "F5 hold over a paused read records")
        XCTAssertEqual(state.mode, .recording)

        gesture.handleKeyUp()
        XCTAssertTrue(scheduled.isEmpty, "hold release does not arm a double-tap timer")
        // Release stops the capture (the daemon keeps the parked read, tts-pause "F5's stop/cancel").
        XCTAssertEqual(sent().map { $0["cmd"] as? String }, ["record", "stop"])
        XCTAssertNil(sent().last?["playback_elapsed_ms"], "the stop is the capture's, not playback's")
        XCTAssertEqual(state.mode, .transcribing)

        // The read identity survives. A local idle alone is not settlement (P16b): Play stays hidden until the
        // daemon's recording-idle, then resumes playback-9.
        state.mode = .idle
        drainMainQueue()
        XCTAssertFalse(state.isPlaybackPaused)
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        drainMainQueue()
        XCTAssertTrue(state.isPlaybackPaused)
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-9")
        gesture.reset()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "queued parked-read restoration completed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testPausedReadRoutesLikeIdleForTapToggleAndStart() {
        for entry in ["tap", "toggle", "start", "primary"] {
            let (state, sent) = pausedState()
            let router = VoiceBarCommandRouter(voiceState: state)
            switch entry {
            case "tap":
                router.handleHotkeySingleTap()
                XCTAssertTrue(sent().isEmpty, "a stray tap never stops the parked read")
                router.handleHotkeyHoldEnd(holdDuration: 0.4)
                XCTAssertTrue(sent().isEmpty, "a hold end with no capture never stops it either")
                XCTAssertTrue(state.isPlaybackPaused)
                continue
            case "toggle": router.handle(controlCommand: .toggle)
            case "start": router.handle(controlCommand: .startRecording)
            default: router.handlePrimaryTap()
            }
            XCTAssertEqual(sent().map { $0["cmd"] as? String }, ["record"], entry)
            XCTAssertEqual(state.mode, .recording, entry)
        }
    }

    func testSpeakingThatIsNotPausedStillStopsOnF5() {
        let state = VoiceState()
        state.isConnected = true
        var sent: [String] = []
        state.sendCommand = { sent.append($0["cmd"] as? String ?? "") }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Live read", "playback_id": "p", "generation": 1])
        let router = VoiceBarCommandRouter(voiceState: state)
        router.handleHotkeyHoldStart()
        XCTAssertTrue(sent.isEmpty)
        router.handleHotkeyHoldEnd(holdDuration: 0.5)
        XCTAssertEqual(sent, ["stop"])
    }

    /// QUEUE1 D2: the unchanged router, inside AppDelegate's F5 scope, stops a playing read but keeps the queue.
    func testF5TapOverAPlayingQueuedReadSendsStopThatRetainsTheQueue() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.isConnected = true
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Queued read", "request_id": "r-A"])
        state.handleEvent(["type": "read_queue", "count": 2, "current_request_id": "r-A"])
        let router = VoiceBarCommandRouter(voiceState: state, resetHotkeyState: {})
        state.retainingReadQueueOnStop { router.handleHotkeySingleTap() }
        XCTAssertEqual(sent.map { $0["cmd"] as? String }, ["stop"])
        XCTAssertEqual(sent.last?["retain_read_queue"] as? Bool, true)
        XCTAssertEqual(state.readQueueCount, 2)
    }
}
