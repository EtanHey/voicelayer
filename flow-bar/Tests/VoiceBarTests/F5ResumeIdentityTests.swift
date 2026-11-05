@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

@MainActor
final class F5ResumeIdentityTests: XCTestCase {
    func testSingleTakeResumesAcknowledgedSelection() throws { try replay(takes: 1, queued: 0) }
    func testN6ResumesAcknowledgedSelectionAfterBothTakesSettle() throws { try replay(takes: 2, queued: 0) }
    func testN6ResumesAcknowledgedSelectionWithTwoWaitingReads() throws { try replay(takes: 2, queued: 2) }
    func testCaptureFailureStillShowsTheDaemonResumedRead() throws { try replay(takes: 1, queued: 0, failed: true) }

    func testStoppedRefusedAndEmptyQueueSelectionsNeverResurrect() throws {
        for ending in ["stop", "resume-refused", "empty-queue"] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.isConnected = true
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed("One two")) }
            state.speakSelection()
            let requestID = try XCTUnwrap(commands.last?["id"] as? String)
            let speech: [String: Any] = ["type": "state", "state": "speaking", "request_id": requestID,
                                       "text": "One two", "playback_id": "read", "generation": 1]
            state.handleEvent(speech)
            state.record(pressToTalk: true)
            state.pendingIntent = nil
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "read",
                               "generation": 2, "pause_owner": "f5", "offset_ms": 1000])
            switch ending {
            case "stop": state.stopSpeechDuringCapture()
            case "resume-refused": state.handleEvent(["type": "playback_outcome", "playback_id": "read",
                                                      "status": "interrupted", "reason": "resume-refused"])
            default: state.handleEvent(["type": "read_queue", "count": 0, "current_request_id": NSNull()])
            }
            state.handleEvent(["type": "state", "state": "idle", "source": "recording", "recording_jobs": [], "mic_take_id": NSNull()])
            var resumed = speech
            resumed["generation"] = 3
            resumed["playback_offset_ms"] = 1000
            state.handleEvent(resumed)
            state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "read", "generation": 3])
            XCTAssertEqual(state.mode, .idle, ending)
        }
    }

    /// F5-owned pause confirmed while still speaking, then the daemon ends playback (speaking -> idle).
    /// Afterwards, Option+F5 on the same text must start a fresh read (send speak_text).
    func testSpeakingToIdleWithF5ParkDoesNotSwallowSameTextRead() throws {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.frontmostAppProvider = { nil }
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("One two")) }
        state.speakSelection()
        let requestID = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "speak_text", "id": requestID, "outcome": "accept"])
        state.handleEvent(["type": "state", "state": "speaking", "request_id": requestID,
                           "text": "One two", "playback_id": "read", "generation": 1])
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "read",
                           "generation": 2, "pause_owner": "f5", "offset_ms": 1000])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.mode, .idle)
        let before = commands.count
        state.speakSelection()
        let sent = commands[before...].contains { $0["cmd"] as? String == "speak_text" }
        XCTAssertTrue(sent, "commands after: \(commands[before...].map { $0["cmd"] ?? "?" })")
    }

    private func replay(takes: Int, queued: Int, failed: Bool = false) throws {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.frontmostAppProvider = { nil }
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("One two three four")) }
        state.speakSelection()
        let requestID = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "speak_text", "id": requestID, "outcome": "accept"])
        let speaking: [String: Any] = [
            "type": "state", "state": "speaking", "request_id": requestID,
            "text": "One two three four", "duration_ms": 4000, "playback_id": "read", "generation": 1,
            "initial_timing": ["type": "subtitle", "words": (0..<4).map {
                ["text": ["One", "two", "three", "four"][$0], "offset_ms": $0 * 1000, "duration_ms": 1000] as [String: Any]
            }],
        ]
        state.handleEvent(speaking)
        for index in 0..<queued {
            state.selectionTextCaptureHandler = { $0(.completed("Waiting \(index)")) }
            state.speakSelection()
            let queuedID = try XCTUnwrap(commands.last?["id"] as? String)
            state.handleEvent(["type": "ack", "command": "speak_text", "id": queuedID, "outcome": "accept"])
        }
        state.handleEvent(["type": "read_queue", "count": queued, "current_request_id": requestID])
        let router = VoiceBarCommandRouter(voiceState: state)
        router.handleHotkeyHoldStart()
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        let recordID = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "record", "id": recordID, "outcome": "accept"])
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "read",
                           "generation": 2, "pause_owner": "f5", "offset_ms": 2000, "chunk_offset_ms": 2000])
        func jobs(_ entries: [(String, String)], mic: String? = nil) {
            state.handleEvent(["type": "state", "state": mic == nil ? (entries.isEmpty ? "idle" : "transcribing") : "recording",
                               "source": "recording", "recording_jobs": entries.map {
                ["take_id": $0.0, "phase": $0.1, "kind": "live"]
            }, "mic_take_id": mic as Any? ?? NSNull()])
        }
        jobs([(a, "capturing")], mic: a)
        router.handleHotkeyHoldEnd(holdDuration: 1)
        state.pendingIntent = nil
        jobs([(a, "processing")])
        if takes == 2 {
            router.handleHotkeyHoldStart()
            let b = try XCTUnwrap(commands.last?["take_id"] as? String)
            XCTAssertNotEqual(a, b)
            state.pendingIntent = nil
            jobs([(a, "processing"), (b, "capturing")], mic: b)
            router.handleHotkeyHoldEnd(holdDuration: 1)
            state.pendingIntent = nil
            jobs([(a, "delivering"), (b, "processing")])
            jobs([(b, "processing")])
            XCTAssertEqual(state.mode, .transcribing)
            jobs([(b, "delivering")])
        }
        if failed {
            state.handleEvent(["type": "error", "take_id": a, "job_kind": "live", "message": "fixture capture failure"])
            XCTAssertEqual(state.mode, .error)
        }
        jobs([])
        XCTAssertEqual(state.mode, failed ? .error : .idle)
        var resumed = speaking
        resumed["generation"] = 3
        resumed["playback_offset_ms"] = 2000
        var speakingEdges = 0
        state.onModeChange = { if $0 == .speaking { speakingEdges += 1 } }
        state.handleEvent(resumed)
        state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "read",
                           "generation": 3, "pause_owner": "f5", "offset_ms": 2000])
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(speakingEdges, 1, "the resumed notice does not show the read twice")
        XCTAssertFalse(state.isPlaybackPaused)
        XCTAssertEqual(state.teleprompterText, "One two three four")
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2000)
        XCTAssertEqual(state.wordBoundaries.count, 4)
        let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode, hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed, isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused, isCollapsed: state.isCollapsed))
        XCTAssertEqual(presentation.visualState, .teleprompter)
        XCTAssertEqual(state.readQueueCount, queued)
        state.togglePlaybackPause()
        XCTAssertEqual(commands.last?["playback_id"] as? String, "read")
        XCTAssertEqual(commands.last?["generation"] as? Int, 3)
        state.stop()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        XCTAssertEqual(commands.last?["playback_elapsed_ms"] as? Int, 2000)
        state.handleEvent(resumed)
        XCTAssertEqual(state.mode, .idle, "a stopped read's late speaking edge cannot resurrect it")
    }
}
