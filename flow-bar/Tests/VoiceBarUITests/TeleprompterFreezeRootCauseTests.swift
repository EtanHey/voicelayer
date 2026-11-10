import AppKit
@testable import VoiceBarUI
import XCTest

/// Phase-one regressions. Synthetic protocol and clock only; no window, audio,
/// socket, live preferences, recording, or system pasteboard access.
@MainActor
final class TeleprompterFreezeRootCauseTests: XCTestCase {
    private var now: TimeInterval = 100

    private func makeState() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            playbackAmplitudeClock: { [unowned self] in now },
            pasteboard: NSPasteboard.withUniqueName())
        state.isConnected = true
        state.sendCommand = { _ in }
        return state
    }

    private func speaking(player: String = "original", utterance: String = "read",
                          request: String? = "submission", offset: Int = 0) -> [String: Any] {
        var event: [String: Any] = [
            "type": "state", "state": "speaking", "text": "One two",
            "playback_id": player, "generation": 1, "utteranceId": utterance,
            "duration_ms": 2000, "chunk_duration_ms": 2000, "playback_offset_ms": offset,
            "readback_id": "retained", "readback_duration_ms": 2000,
        ]
        if let request { event["request_id"] = request }
        return event
    }

    func testV36TimingNoticeAgreesWithTheTableThatHighlightsWords() throws {
        let state = makeState()
        state.handleEvent(speaking())
        state.handleEvent([
            "type": "speech_words", "utteranceId": "read", "wordOffset": 0, "approximate": false,
            "words": [["text": "One", "startMs": 0, "endMs": 900],
                      ["text": "two", "startMs": 1000, "endMs": 1900]],
        ])
        let table = try XCTUnwrap(state.speechWords)
        XCTAssertEqual(table.wordIndex(atMilliseconds: 1200), 1)
        XCTAssertTrue(state.isTeleprompterScrubSeekable)
        XCTAssertNil(TeleprompterPlaybackScrubBar(state: state).timingNotice,
                     "The active word table supplies timing even without a legacy subtitle event")
    }

    func testTimingNoticeTracksReadIdentityAndDoesNotAuthorizeMissingAudio() {
        let state = makeState()
        var event = speaking()
        event.removeValue(forKey: "duration_ms")
        event.removeValue(forKey: "chunk_duration_ms")
        state.handleEvent(event)
        let timing: [String: Any] = [
            "type": "speech_words", "utteranceId": "read", "wordOffset": 0,
            "words": [["text": "One", "startMs": 0, "endMs": 900]],
        ]
        state.handleEvent(timing)
        XCTAssertFalse(state.isTeleprompterScrubSeekable, "Timing cannot create seekable audio")
        state.handleEvent(speaking())
        state.handleEvent(timing)
        XCTAssertNil(TeleprompterPlaybackScrubBar(state: state).timingNotice)
        state.handleEvent(speaking(player: "new", utterance: "new-read", request: "new-request"))
        state.handleEvent(timing)
        XCTAssertEqual(TeleprompterPlaybackScrubBar(state: state).timingNotice, "Word timing unavailable",
                       "A stale table cannot supply timing for the new read")
    }

    func testV37AcceptedReadbackSeekMustAdoptItsNewPlayer() {
        let state = makeState()
        state.handleEvent(speaking())
        now += 2
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        state.seek(offsetMs: 0)
        // A delayed old frame still cannot resurrect the retired submission.
        state.handleEvent(speaking(player: "replayed", utterance: "readback-1"))
        XCTAssertEqual(state.mode, .idle)
        state.handleEvent(speaking(player: "replayed", utterance: "readback-1", request: "fresh-replay"))
        XCTAssertEqual(state.mode, .speaking, "An accepted user readback seek must restart the display clock")
        XCTAssertEqual(state.speechWords?.utteranceID, "readback-1")
    }

    func testV357ReturningFromPreviousReadRestoresTheHeldPresentation() { assertPreviousReturn() }
    func testPreviousReturnAfterOptimisticStop() { assertPreviousReturn(exit: "stop") }
    func testPreviousReturnAfterLegacyShortReadIdle() { assertPreviousReturn(exit: "idle") }
    func testPreviousReturnOfAPreparingRead() { assertPreviousReturn(preparing: true) }

    private func assertPreviousReturn(exit: String = "completed", preparing: Bool = false) {
        let state = makeState()
        var initial = speaking()
        if preparing {
            initial.removeValue(forKey: "playback_id")
            initial["long_read"] = ["id": "read", "chunk_index": 0, "preparing": true]
        }
        state.handleEvent(initial)
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "original",
                           "generation": 2, "offset_ms": 1000, "pause_owner": "user"])
        // Previous-read playback changes the surface while retaining the current
        // read in the daemon. Its completion returns that read paused.
        var previous = speaking(player: "previous", utterance: "previous-read", request: nil)
        previous["previous_read_hold"] = ["playback_id": "original", "generation": 2, "utterance_id": "read"]
        state.handleEvent(previous)
        if exit == "stop" { state.stop() }
        if exit == "idle" { state.handleEvent(["type": "state", "state": "idle", "source": "playback"]) }
        state.handleEvent(["type": "playback_outcome", "playback_id": "previous", "status": "completed"])
        // The daemon now publishes a correlated complete presentation before its pause.
        var returned = speaking(offset: 1000)
        returned["generation"] = 2
        returned["previous_read_return"] = ["from_playback_id": "previous", "offset_ms": 1000, "pause_owner": "user"]
        state.handleEvent(returned)
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "original",
                           "generation": 2, "offset_ms": 1000, "pause_owner": "user"])
        XCTAssertEqual(state.speechWords?.utteranceID, "read", "Returning a held read must re-adopt its identity")
        XCTAssertTrue(state.isPlaybackPaused, "The returned read is paused, not the completed previous player")
        now += 10
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 1000, "A return freezes at the held word")
        var command: [String: Any] = [:]
        state.sendCommand = { command = $0 }
        _ = state.togglePlaybackPause()
        XCTAssertEqual(command["cmd"] as? String, "resume")
        XCTAssertEqual(command["playback_id"] as? String, "original")
        XCTAssertEqual(command["generation"] as? Int, 2)
    }

    func testPreviousReturnCannotReplaceANewerReadOrAuthorizeForeignPause() {
        let state = makeState()
        state.handleEvent(speaking())
        var previous = speaking(player: "previous", request: nil)
        previous["previous_read_hold"] = ["playback_id": "original", "generation": 1]
        state.handleEvent(previous)
        state.handleEvent(speaking(player: "newer", utterance: "newer-read", request: "newer-request"))
        var staleReturn = speaking(player: "held", request: "held-return")
        staleReturn["previous_read_return"] = ["from_playback_id": "previous", "offset_ms": 1000, "pause_owner": "user"]
        state.handleEvent(staleReturn)
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "held",
                           "generation": 2, "offset_ms": 1000, "pause_owner": "user"])
        XCTAssertEqual(state.speechWords?.utteranceID, "newer-read")
        XCTAssertFalse(state.isPlaybackPaused)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.handleEvent(staleReturn)
        XCTAssertEqual(state.mode, .idle, "A superseded loan cannot return after the newer read ends")
    }

    func testV35OrdinaryPlaybackIdleFinishesTheClock() {
        let state = makeState()
        state.handleEvent(speaking())
        now += 2
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(state.showsPlaybackClock)
        XCTAssertTrue(state.isTeleprompterReadback)
    }

    func testV37PausedScrubberMustNotOfferARejectedSeek() {
        let state = makeState()
        state.handleEvent(speaking())
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "original",
                           "generation": 2, "offset_ms": 1000, "pause_owner": "user"])
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertFalse(state.isTeleprompterScrubSeekable,
                       "seekPlayback explicitly rejects paused reads; the slider must honor that gate")
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.seek(offsetMs: 500)
        XCTAssertTrue(commands.isEmpty, "A drag begun before pause must not send after pause")
    }

    func testV37LiveSeekWithCurrentSubmissionAdoptsTheReplacement() {
        let state = makeState()
        state.handleEvent(speaking())
        state.seek(offsetMs: 1000)
        var landed = speaking(player: "sought", offset: 1000)
        landed["reanchor"] = "seek"
        state.handleEvent(landed)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 1000)
        XCTAssertEqual(state.speechWords?.utteranceID, "read")
    }
}
