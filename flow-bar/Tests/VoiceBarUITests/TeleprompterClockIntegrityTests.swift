@testable import VoiceBarUI
import XCTest

/// T1 (QA 2026-11-08, VoiceBar 2.3.0 @ 870b1617): the teleprompter clock is the player's position. It starts with
/// the player, never counts during "Preparing speech…", never passes the end, never steps back without a seek,
/// and a Pause click is never silently dead.
@MainActor
final class TeleprompterClockIntegrityTests: XCTestCase {
    private var now: TimeInterval = 100

    private func makeState() -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        return (state, { sent })
    }

    private let document = "One two three four five six"

    private func preparing() -> [String: Any] {
        ["type": "state", "state": "speaking", "text": "Preparing speech…", "utteranceId": "read-1",
         "long_read": ["id": "read-1", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0, "preparing": true,
                       "text": document, "chunk_word_starts": [0, 3]]]
    }

    private func chunk(_ index: Int, start: Int, offset: Int? = nil, chunkDuration: Int? = 3000,
                       total: Int = 6000, playbackID: String, generation: Int = 1) -> [String: Any] {
        var event: [String: Any] = [
            "type": "state", "state": "speaking", "text": index == 0 ? "One two three" : "four five six",
            "utteranceId": "read-1", "playback_id": playbackID, "generation": generation,
            "playback_offset_ms": offset ?? start, "duration_ms": total,
            "long_read": ["id": "read-1", "chunk_index": index, "chunk_count": 2, "chunk_start_ms": start],
        ]
        if let chunkDuration { event["chunk_duration_ms"] = chunkDuration }
        return event
    }

    // MARK: - S1-F6r: no counter while preparing; the clock starts with the player

    func testPreparingSpeechShowsNoRunningCounterAndTheClockStartsWithThePlayer() {
        let (state, _) = makeState()
        state.handleEvent(preparing())
        now += 2.4
        XCTAssertFalse(state.showsPlaybackClock, "Preparing speech… has no player, so no counter")
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 0)

        state.handleEvent(chunk(0, start: 0, playbackID: "p-1"))
        XCTAssertTrue(state.showsPlaybackClock)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 0, "the player's first frame is 0:00, never a reset")
        now += 1.2
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 1200)
    }

    // MARK: - S2-F5 / S4-F4: never past the total

    func testElapsedNeverPassesTheTotal() {
        let (state, _) = makeState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Short reply", "duration_ms": 7000,
                           "playback_id": "p-1", "generation": 1])
        now += 8
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 7000, "0:08 / 0:07 is not a position")
        now += 120
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 7000)
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 7)
    }

    // MARK: - S3-F2 / S1-F6r: a chunk edge never rolls the clock back

    func testTheClockHoldsAtTheChunkEndWhileTheNextChunkIsOnItsWay() {
        let (state, _) = makeState()
        state.handleEvent(preparing())
        state.handleEvent(chunk(0, start: 0, playbackID: "p-1"))
        now += 3.4 // the player ran out of chunk 0's 3 s; chunk 1's player has not started yet
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3000, "the player cannot be past the audio it holds")

        state.handleEvent(chunk(1, start: 3000, playbackID: "p-2"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3000, "0:03 → 0:02 was the visible rollback")
        now += 0.5
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3500)
    }

    func testAnOlderDaemonsChunkEdgeHoldsTheShownTimeUntilThePlayerCatchesUp() {
        let (state, _) = makeState()
        state.handleEvent(preparing())
        state.handleEvent(chunk(0, start: 0, chunkDuration: nil, playbackID: "p-1"))
        now += 3.4
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3400)

        state.handleEvent(chunk(1, start: 3000, chunkDuration: nil, playbackID: "p-2"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3400, "no backward step without a seek")
        now += 0.2
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3400)
        now += 0.3
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3500)
    }

    // MARK: - S2-F6: a seek still moves the clock, backwards too

    func testASeekReanchorsTheClockBackwards() {
        let (state, _) = makeState()
        state.handleEvent(preparing())
        state.handleEvent(chunk(0, start: 0, playbackID: "p-1"))
        state.handleEvent(chunk(1, start: 3000, playbackID: "p-2"))
        now += 2
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 5000)
        state.handleEvent(chunk(0, start: 0, offset: 500, playbackID: "p-3"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 500, "a seek is the one thing that moves the clock back")
    }

    // MARK: - S2-F9: Pause is never silently dead

    func testAStalePauseAdoptsTheCurrentPlayerAndRetriesOnce() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-20", generation: 3))
        state.togglePlaybackPause()
        let first = sent().last
        XCTAssertEqual(first?["playback_id"] as? String, "p-20")

        // A scrub replaced the player; the app never saw the new player's speaking edge.
        state.handleEvent(["type": "ack", "command": "pause", "id": first?["id"] as Any, "outcome": "reject",
                           "reason": "stale", "playback_id": "p-21", "generation": 1, "utterance_id": "read-1"])
        let retry = sent().last
        XCTAssertEqual(sent().count, 2, "the click is sent once more, scoped to the player that is current")
        XCTAssertEqual(retry?["cmd"] as? String, "pause")
        XCTAssertEqual(retry?["playback_id"] as? String, "p-21")
        XCTAssertEqual(retry?["generation"] as? Int, 1)
        XCTAssertNil(retry?["playback_elapsed_ms"], "the daemon pauses the new player at its own cursor")

        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-21", "generation": 2,
                           "offset_ms": 1500, "chunk_offset_ms": 1500])
        XCTAssertTrue(state.isPlaybackPaused, "the glyph flips to Play")
        now += 30
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 1500, "and the counter stops")
    }

    func testASecondStaleRejectExplainsItselfInsteadOfLooping() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-20", generation: 3))
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last?["id"] as Any, "outcome": "reject",
                           "reason": "stale", "playback_id": "p-21", "generation": 1, "utterance_id": "read-1"])
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last?["id"] as Any, "outcome": "reject",
                           "reason": "stale", "playback_id": "p-22", "generation": 1, "utterance_id": "read-1"])
        XCTAssertEqual(sent().count, 2, "one retry, never a loop")
        XCTAssertEqual(state.confirmationText, "Pause unavailable")
    }

    func testAStaleRejectWithoutAnIdentityIsNotSilent() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-20", generation: 3))
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last?["id"] as Any, "outcome": "reject",
                           "reason": "stale"])
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(state.confirmationText, "Pause unavailable")
    }

    // MARK: - #809 review round 2 (Codex probes, review-809-evidence/Review809AdversarialTests.swift)

    /// P1, verbatim probe: A's late stale reject must never pause B. A ended, B replaced it, and the reject names B.
    func testLateStaleAckMustNotPauseReplacementRead() {
        let state = VoiceState()
        state.isConnected = true
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Read A", "playback_id": "A", "generation": 1])
        state.togglePlaybackPause()
        let first = sent.last!["id"]!
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.handleEvent(["type": "state", "state": "speaking", "text": "Read B", "playback_id": "B", "generation": 1])
        state.handleEvent(["type": "ack", "command": "pause", "id": first, "outcome": "reject", "reason": "stale",
                           "playback_id": "B", "generation": 1])
        XCTAssertEqual(sent.count, 1, "A's pending click must not be retried against B; actual last scope: \(sent.last!)")
        XCTAssertNil(state.confirmationText, "the screen already shows B; nothing to explain")
    }

    /// P1, the same with logical read ids: B's reject names B's read, not A's, so A's click is dropped.
    func testAStaleRejectNamingAnotherLogicalReadIsNeverRetried() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-1", generation: 3))
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last?["id"] as Any, "outcome": "reject",
                           "reason": "stale", "playback_id": "p-9", "generation": 1, "utterance_id": "another-read"])
        XCTAssertEqual(sent().count, 1)
    }

    /// P1: a Resume intent is bound to its read the same way.
    func testAStaleResumeForAReplacedReadIsDropped() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-1", generation: 1))
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 900, "chunk_offset_ms": 900])
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["cmd"] as? String, "resume")
        var other = chunk(0, start: 0, playbackID: "q-1", generation: 1)
        other["utteranceId"] = "read-2"
        state.handleEvent(other)
        state.handleEvent(["type": "ack", "command": "resume", "id": sent()[sent().count - 1]["id"] as Any,
                           "outcome": "reject", "reason": "stale", "playback_id": "q-1", "generation": 1,
                           "utterance_id": "read-1"])
        XCTAssertEqual(sent().count, 1, "read-1 is no longer on screen: its Resume is never retried")
    }

    /// P1 (stale cursor), probe with the read's id: 9 s belongs to the old player; an unseen seek moved it to 1 s.
    func testResyncMustNotReuseClockFromBeforeUnseenSeek() {
        let (state, sent) = makeState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Read A", "playback_id": "A", "generation": 3,
                           "duration_ms": 10000, "utteranceId": "R"])
        now += 9
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last?["playback_elapsed_ms"] as? Int, 9000)
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last!["id"]!, "outcome": "reject",
                           "reason": "stale", "playback_id": "A2", "generation": 1, "utterance_id": "R",
                           "chunk_start_ms": 0, "chunk_duration_ms": 10000, "duration_ms": 10000])
        XCTAssertEqual(sent().count, 2)
        XCTAssertNil(sent().last?["playback_elapsed_ms"],
                     "9 s belongs to the old player; the retry must let the daemon use its actual 1 s cursor")
    }

    /// P1 (stale bounds), probe with the read's id: the paused player is in chunk 1, so chunk 0's end cannot clamp it.
    func testCrossChunkRecoveryMustUseTheNewChunksClockBounds() {
        let (state, sent) = makeState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Chunk zero", "playback_id": "A", "generation": 3,
                           "duration_ms": 6000, "chunk_duration_ms": 3000, "playback_offset_ms": 0, "utteranceId": "R",
                           "long_read": ["id": "R", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0]])
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last!["id"]!, "outcome": "reject",
                           "reason": "stale", "playback_id": "B", "generation": 1, "utterance_id": "R"])
        XCTAssertEqual(sent().last?["playback_id"] as? String, "B")
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "B", "generation": 2,
                           "offset_ms": 4500, "chunk_offset_ms": 1500, "duration_ms": 6000,
                           "long_read": ["id": "R", "chunk_index": 1, "chunk_count": 2, "chunk_start_ms": 3000]])
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 4500, "the paused player is in chunk 1; chunk 0's 3000 ms bound is stale")
    }

    /// P2 via the reject itself: its chunk geometry replaces the old player's before any clamp.
    func testTheRejectsChunkGeometryReplacesTheOldPlayersBounds() {
        let (state, sent) = makeState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Chunk zero", "playback_id": "A", "generation": 3,
                           "duration_ms": 6000, "chunk_duration_ms": 3000, "utteranceId": "R",
                           "long_read": ["id": "R", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0]])
        now += 5
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3000)
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last!["id"]!, "outcome": "reject",
                           "reason": "stale", "playback_id": "B", "generation": 1, "utterance_id": "R",
                           "chunk_start_ms": 3000, "chunk_duration_ms": 3000, "duration_ms": 6000])
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 5000, "bounded by chunk 1 (3–6 s), not chunk 0")
    }

    func testPauseWhileNoPlayerExistsSaysSoAndKeepsTheRead() {
        let (state, sent) = makeState()
        state.handleEvent(chunk(0, start: 0, playbackID: "p-20"))
        state.togglePlaybackPause()
        state.handleEvent(["type": "ack", "command": "pause", "id": sent().last?["id"] as Any, "outcome": "noop",
                           "reason": "nothing playing"])
        XCTAssertEqual(state.mode, .speaking, "a scrub's gap is not the end of the read")
        XCTAssertEqual(state.confirmationText, "Speech is loading. Try again")
    }
}
