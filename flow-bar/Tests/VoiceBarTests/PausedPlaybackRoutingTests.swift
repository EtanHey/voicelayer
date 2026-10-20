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
        let router = VoiceBarCommandRouter(voiceState: state, resetHotkeyState: { gesture.reset() })
        gesture.onHoldStart = { router.handleHotkeyHoldStart() }
        gesture.onHoldEnd = { router.handleHotkeyHoldEnd(holdDuration: 1.2) }
        gesture.onSingleTap = { router.handleHotkeySingleTap() }

        gesture.handleKeyDown()
        RunLoop.main.run(until: Date().addingTimeInterval(Double(GestureStateMachine.holdThresholdMs + 120) / 1000))
        XCTAssertEqual(sent().map { $0["cmd"] as? String }, ["record"], "F5 hold over a paused read records")
        XCTAssertEqual(state.mode, .recording)

        gesture.handleKeyUp()
        RunLoop.main.run(until: Date().addingTimeInterval(Double(GestureStateMachine.doubleTapWindowMs + 120) / 1000))
        // Release stops the capture (the daemon keeps the parked read, tts-pause "F5's stop/cancel").
        XCTAssertEqual(sent().map { $0["cmd"] as? String }, ["record", "stop"])
        XCTAssertNil(sent().last?["playback_elapsed_ms"], "the stop is the capture's, not playback's")
        XCTAssertEqual(state.mode, .transcribing)

        // The read identity survives: when the capture settles (transcribed and delivered), Play resumes playback-9.
        state.mode = .idle
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(state.isPlaybackPaused)
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent().last?["playback_id"] as? String, "playback-9")
        gesture.reset()
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
