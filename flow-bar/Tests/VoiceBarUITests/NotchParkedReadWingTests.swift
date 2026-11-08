@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A, QA row 4: a read the user paused, then a dictation. While "Typed" holds the notch the read is parked
/// and the bar is idle, so 2.3 drew D2's interrupted-idle wing (Next +N, no Play) and reshuffled when the read came
/// back. The wing now keeps the paused read's layout for that moment, and Play brings the read back at once.
@MainActor
final class NotchParkedReadWingTests: XCTestCase {
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    private func dictatedOverAPausedRead(queue: Int = 0) -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            playbackAmplitudeClock: { 100 }
        )
        state.isConnected = true
        state.frontmostAppProvider = { nil }
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Parked read", "duration_ms": 6000,
                           "playback_id": "A", "generation": 1])
        if queue > 0 {
            state.handleEvent(["type": "read_queue", "count": queue, "current_request_id": "req-A"])
        }
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "A", "generation": 2,
                           "offset_ms": 2500, "chunk_offset_ms": 2500, "duration_ms": 6000,
                           "word_index": 2, "word_count": 2])
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        state.confirmationText = "Typed"
        drain()
        return (state, { sent })
    }

    func testWhileTypedShowsThePausedReadKeepsPlayInTheWing() {
        let (state, _) = dictatedOverAPausedRead()
        XCTAssertEqual(state.mode, .idle, "the dictation's feedback holds the notch")
        XCTAssertTrue(state.isParkedReadAwaitingFeedback)
        XCTAssertEqual(VoiceBarPresentation.playbackPauseControl(for: state)?.iconName, "play.fill",
                       "Play stays on the left (2.3 dropped it here)")
        XCTAssertNil(VoiceBarPresentation.playbackPauseControl(mode: state.mode, isPaused: state.isPlaybackPaused,
                                                               isReadback: false),
                     "what 2.3 drew: no Play while idle")
    }

    func testWithAQueueTheLeftWingKeepsPlayNextAndCount() {
        let (state, _) = dictatedOverAPausedRead(queue: 1)
        let queue = VoiceBarPresentation.readQueueControl(for: state)
        XCTAssertEqual(queue?.leadingSlotCount, 3, "Play, Next and +1: the paused layout, not D2's two slots")
        XCTAssertEqual(queue?.countLabel, "+1")
    }

    func testPlayDuringTypedBringsTheReadBackPaused() {
        let (state, sent) = dictatedOverAPausedRead()
        let before = sent().count
        state.restoreParkedReadNow()
        drain()
        XCTAssertNil(state.confirmationText)
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertTrue(state.isPlaybackPaused, "back on the same word, still paused")
        XCTAssertFalse(state.isParkedReadAwaitingFeedback)
        XCTAssertEqual(sent().count, before, "no playback command: the same restore path, nothing resumed")
    }

    func testAnF5ParkedReadOrNoParkedReadIsUnchanged() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.confirmationText = "Typed"
        XCTAssertFalse(state.isParkedReadAwaitingFeedback)
        XCTAssertNil(VoiceBarPresentation.playbackPauseControl(for: state))
        state.restoreParkedReadNow()
        XCTAssertEqual(state.confirmationText, "Typed", "nothing to bring back: the feedback stays")
    }
}
