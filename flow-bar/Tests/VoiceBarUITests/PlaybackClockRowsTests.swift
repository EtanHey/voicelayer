@testable import VoiceBarUI
import XCTest

/// Lane B P0 (Etan, 2026-11-08 4:40 pm: "the read clock is broken statewise, really broken"). One case per FAIL row of
/// the rigorous QA of 6d03eae7 (qa-1147-rigorous/inventory-all.md), each fail-first on 849483ae. The daemon side is
/// formal/playback-session (TeleTracksAudio, ResumeExact) plus playback-engine.test.ts.
///
/// The frames' readouts point at one mechanism: the clock was clamped to a chunk whose speaking edge the notch last
/// applied (frozen at that chunk's end), and Pause then showed the daemon's real position (the jump). The daemon now
/// reports its player's position (`playback_position`); the notch re-anchors to it, never moves backwards on a stale
/// edge, and asks for a resync when a read plays that it is not showing.
@MainActor
final class PlaybackClockRowsTests: XCTestCase {
    private var now: TimeInterval = 100

    private func makeState() -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        return (state, { sent })
    }

    /// A read whose first chunk edge (0 to `chunkMs`) is the last one the notch applied.
    private func chunkEdge(offset: Int = 0, chunkStart: Int = 0, chunkMs: Int, total: Int, playbackID: String = "p-1",
                           generation: Int = 1, reanchor: String? = nil) -> [String: Any] {
        var edge: [String: Any] = ["type": "state", "state": "speaking", "text": "QA read text for the clock rows",
                                   "utteranceId": "read-1", "playback_id": playbackID, "generation": generation,
                                   "playback_offset_ms": offset, "duration_ms": total, "chunk_duration_ms": chunkMs,
                                   "long_read": ["id": "read-1", "chunk_index": chunkStart == 0 ? 0 : 1, "chunk_count": 4,
                                                 "chunk_start_ms": chunkStart]]
        if let reanchor { edge["reanchor"] = reanchor }
        return edge
    }

    private func position(_ offset: Int, chunkStart: Int, chunkMs: Int, total: Int, playbackID: String = "p-2") -> [String: Any] {
        ["type": "playback_position", "playback_id": playbackID, "generation": 1, "utterance_id": "read-1",
         "offset_ms": offset, "chunk_start_ms": chunkStart, "chunk_duration_ms": chunkMs, "duration_ms": total,
         "word_index": offset / 1000]
    }

    /// Plays wall time forward with the daemon's 4 Hz position reports for a later chunk the notch never got an edge for.
    private func play(_ state: VoiceState, from start: Int, to end: Int, chunkStart: Int, chunkMs: Int, total: Int) {
        var t = start
        while t < end {
            t = min(end, t + 250)
            now += 0.25
            state.handleEvent(position(t, chunkStart: chunkStart, chunkMs: chunkMs, total: total))
        }
    }

    // MARK: - Frozen "Reading" (k04-49, k04-58, k06-22, k07-64)

    func testK04_49_K04_58_K06_22_K07_64_aMissedChunkEdgeNeverFreezesTheClock() {
        let (state, _) = makeState()
        // k04-49: chunk 0 is 0:00-0:09 of a 0:59 read; the next chunk's edge never lands.
        state.handleEvent(chunkEdge(chunkMs: 9000, total: 59_000))
        now += 9
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 9000)
        play(state, from: 9000, to: 19_000, chunkStart: 9000, chunkMs: 20_000, total: 59_000)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 19_000, "k04-49: 'Reading' frozen at 0:09 for 10 s")
        // The highlight follows the same clock (the words of the table come from it).
        XCTAssertTrue(state.showsPlaybackClock)
    }

    // MARK: - Pause jumps (k03-45, k04-54, k07-46, k07-61, k04-66)

    func testK03_45_K04_54_K07_46_K07_61_K04_66_pauseShowsThePositionItAlreadyShowed() {
        // (row, the stale chunk end the notch was frozen at, where the audio really was when Pause landed)
        let rows: [(String, Int, Int)] = [("k03-45/k04-54", 9000, 43_000), ("k07-46", 10_000, 41_000),
                                          ("k07-61", 10_000, 38_000), ("k04-66", 1000, 4000)]
        for (row, stale, real) in rows {
            let (state, sent) = makeState()
            state.handleEvent(chunkEdge(chunkMs: stale, total: 64_000))
            now += Double(stale) / 1000
            play(state, from: stale, to: real, chunkStart: stale, chunkMs: 64_000 - stale, total: 64_000)
            let shown = state.playbackElapsedMilliseconds()
            XCTAssertLessThanOrEqual(abs(shown - real), 300, "\(row): showed \(shown) ms while the audio was at \(real) ms")
            state.togglePlaybackPause()
            XCTAssertEqual(sent().last { $0["cmd"] as? String == "pause" }?["playback_elapsed_ms"] as? Int, shown)
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-2", "generation": 2,
                               "offset_ms": real, "chunk_offset_ms": real - stale, "pause_owner": "user"])
            XCTAssertLessThanOrEqual(abs(state.playbackElapsedMilliseconds() - shown), 300, "\(row): Pause moved the clock")
        }
    }

    // MARK: - Resume (k04-57)

    func testK04_57_resumeLandsWhereItPausedAndRunsOn() {
        let (state, _) = makeState()
        state.handleEvent(chunkEdge(offset: 40_000, chunkStart: 40_000, chunkMs: 20_000, total: 60_000))
        now += 3
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 43_000, "chunk_offset_ms": 3000, "pause_owner": "user"])
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 43_000)
        now += 5
        state.handleEvent(chunkEdge(offset: 43_000, chunkStart: 40_000, chunkMs: 20_000, total: 60_000, generation: 3, reanchor: "resume"))
        state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "p-1", "generation": 3,
                           "offset_ms": 43_000, "chunk_offset_ms": 3000])
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 43_000, "k04-57: resume showed 0:53 for a 0:43 pause")
        now += 1
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 44_000)
    }

    // MARK: - Backwards (k03-21, k07-29, k04-63)

    func testK03_21_K07_29_K04_63_aStaleEdgeNeverRunsTheClockBackwards() {
        let (state, _) = makeState()
        state.handleEvent(chunkEdge(chunkMs: 20_000, total: 20_000))
        now += 8
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 8000)
        // k07-29: 0:08 → 0:04 with no click. An edge of the same read, lower, with no re-anchor, is stale.
        state.handleEvent(chunkEdge(offset: 4000, chunkMs: 20_000, total: 20_000, generation: 1))
        XCTAssertGreaterThanOrEqual(state.playbackElapsedMilliseconds(), 8000, "k07-29: the clock ran backwards")
        now += 1
        XCTAssertGreaterThanOrEqual(state.playbackElapsedMilliseconds(), 9000)
        // A real seek still moves it back.
        state.handleEvent(chunkEdge(offset: 2000, chunkMs: 20_000, total: 20_000, generation: 2, reanchor: "seek"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2000, "a seek is a real re-anchor")
    }

    // MARK: - Completion (k06-31)

    func testK06_31_completionNeverShrinksTheElapsedOrTheTotal() {
        let (state, _) = makeState()
        // The last chunk (0:07-0:13 of a 0:13 read) carries a retained span covering only 6 s.
        var edge = chunkEdge(offset: 7000, chunkStart: 7000, chunkMs: 6000, total: 13_000)
        edge["readback_id"] = "rb-1"
        edge["readback_duration_ms"] = 6000
        state.handleEvent(edge)
        now += 6
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 13)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 13, "k06-31: the total dropped 0:13 → 0:06")
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 13, "k06-31: the elapsed dropped 0:13 → 0:06")
    }

    // MARK: - S-01: the second Ask's restored read plays while the notch shows idle

    func testS01_aReadPlayingThatTheNotchIsNotShowingIsResyncedOnce() {
        let (state, sent) = makeState()
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertEqual(state.mode, .idle)
        state.handleEvent(position(41_000, chunkStart: 30_000, chunkMs: 20_000, total: 64_000, playbackID: "p-9"))
        now += 0.25
        state.handleEvent(position(41_250, chunkStart: 30_000, chunkMs: 20_000, total: 64_000, playbackID: "p-9"))
        let resyncs = sent().filter { $0["cmd"] as? String == "resync_playback" }
        XCTAssertEqual(resyncs.count, 1, "S-01: one resync per playback, not one per heartbeat")
        // The daemon re-sends the read at its live position; the read UI is attached again.
        state.handleEvent(chunkEdge(offset: 41_250, chunkStart: 30_000, chunkMs: 20_000, total: 64_000, playbackID: "p-9",
                                    generation: 3, reanchor: "resync"))
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 41_250)
    }

    func testAPositionDuringACaptureNeverResyncs() {
        let (state, sent) = makeState()
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad"])
        state.handleEvent(position(5000, chunkStart: 0, chunkMs: 9000, total: 9000, playbackID: "p-3"))
        XCTAssertTrue(sent().filter { $0["cmd"] as? String == "resync_playback" }.isEmpty)
    }
}
