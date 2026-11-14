@testable import VoiceBarUI
import XCTest

/// Selection policy, 2026-11-08: empty toggles Pause; identical text reports duplication;
/// different text joins the narration queue. Models:
/// formal/playback-session OptF5Empty/OptF5Same/OptF5Other (NoSameQueued) and formal/speech-queue QueueAdmission
/// (PlayingPolicy "hint"). The daemon side is src/__tests__/selection-admission.test.ts.
@MainActor
final class OptionF5OverReadTests: XCTestCase {
    private var commands: [[String: Any]] = []
    private var cmds: [String] { commands.compactMap { $0["cmd"] as? String } }

    private func reading(_ text: String = "QA read on screen", elapsedMilliseconds: Int = 0,
                         clock: @escaping () -> TimeInterval = { 100 }) -> VoiceState {
        let state = VoiceState(playbackAmplitudeClock: clock)
        state.isConnected = true
        state.isCollapsed = false
        commands = []
        state.sendCommand = { [unowned self] in commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text)) }
        state.speakSelection()
        let id = commands.last?["id"] as? String ?? ""
        state.handleEvent(["type": "state", "state": "speaking", "request_id": id, "text": text, "utteranceId": "read-1",
                           "playback_id": "p-1", "generation": 1, "playback_offset_ms": elapsedMilliseconds, "duration_ms": 20_000,
                           "long_read": ["id": "read-1", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0]])
        commands = []
        return state
    }

    func testEmptySelectionPausesThenResumesTheRead() {
        let state = reading()
        state.selectionTextCaptureHandler = { $0(.nothingSelected) }
        state.speakSelection()
        XCTAssertEqual(cmds, ["pause"], "empty: pause the current read")
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 3000, "chunk_offset_ms": 3000, "pause_owner": "user"])
        XCTAssertTrue(state.isPlaybackPaused)
        commands = []
        state.speakSelection()
        XCTAssertEqual(cmds, ["resume"], "empty again: resume (toggle)")
    }

    func testSameTextDedupesWithANoticeAndKeepsThePosition() {
        // Hold the clock fixed: the live player is allowed to advance during selection capture.
        // A nonzero position ensures a rewind/restart cannot pass as preserved playback.
        let state = reading("QA read on screen", elapsedMilliseconds: 7000)
        let shownBefore = state.playbackElapsedMilliseconds()
        XCTAssertEqual(shownBefore, 7000)
        state.selectionTextCaptureHandler = { $0(.completed("  QA  read\non screen ")) }
        state.speakSelection()
        XCTAssertEqual(cmds, [], "same text: no second read, no Stop, no Next")
        XCTAssertEqual(state.selectionFeedbackNote, VoiceState.alreadyReadingNote)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), shownBefore)
        XCTAssertEqual(state.mode, .speaking)
    }

    func testSameTextDedupeAllowsClockProgressWithoutRestartingTheRead() {
        var now: TimeInterval = 100
        let state = reading("QA read on screen", elapsedMilliseconds: 7000, clock: { now })
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 7000)
        state.selectionTextCaptureHandler = { complete in
            now += 0.002 // Selection capture took 2 ms while playback continued.
            complete(.completed("  QA  read\non screen "))
        }
        state.speakSelection()
        XCTAssertEqual(cmds, [], "same text never restarts, stops or advances the queue")
        XCTAssertEqual(state.selectionFeedbackNote, VoiceState.alreadyReadingNote)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 7002)
        XCTAssertEqual(state.mode, .speaking)
    }

    func testSameTextOverAPausedReadDedupesToo() {
        let state = reading("QA read on screen")
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 3000, "chunk_offset_ms": 3000, "pause_owner": "user"])
        state.selectionTextCaptureHandler = { $0(.completed("QA read on screen")) }
        state.speakSelection()
        XCTAssertEqual(cmds, [])
        XCTAssertEqual(state.selectionFeedbackNote, VoiceState.alreadyReadingNote)
        XCTAssertTrue(state.isPlaybackPaused, "the paused read keeps its position and stays paused")
    }

    func testDifferentTextJoinsTheNarrationQueueWithoutInterrupting() {
        let state = reading()
        state.selectionTextCaptureHandler = { $0(.completed("A different paragraph")) }
        state.speakSelection()
        XCTAssertEqual(cmds, ["speak_text"])
        XCTAssertEqual(commands.last?["queue"] as? Bool, true, "different text queues behind the read")
        XCTAssertEqual(state.mode, .speaking)
    }

    func testTheDaemonsDedupeAckShowsTheNotice() {
        let state = reading()
        state.selectionTextCaptureHandler = { $0(.completed("Another read")) }
        state.speakSelection()
        let id = commands.last?["id"] as? String ?? ""
        state.handleEvent(["type": "ack", "command": "speak_text", "id": id, "outcome": "noop", "reason": "Already reading this"])
        XCTAssertEqual(state.selectionFeedbackNote, VoiceState.alreadyReadingNote)
    }
}
