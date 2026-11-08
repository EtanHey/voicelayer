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
            let next = min(end, t + 250)
            now += Double(next - t) / 1000
            t = next
            state.handleEvent(position(t, chunkStart: chunkStart, chunkMs: chunkMs, total: total))
        }
    }

    // MARK: - Row kinds (#818 review: one test per row id, each reproducing its own kind)

    /// FROZEN LABEL: "Reading" with the clock stuck at a stale chunk end while the audio plays on.
    private func assertFrozenLabelRow(_ row: String, frozenAt stale: Int, forMs span: Int, total: Int,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let (state, _) = makeState()
        state.handleEvent(chunkEdge(chunkMs: stale, total: total))
        now += Double(stale) / 1000
        XCTAssertEqual(state.playbackElapsedMilliseconds(), stale, "\(row): setup", file: file, line: line)
        play(state, from: stale, to: stale + span, chunkStart: stale, chunkMs: total - stale, total: total)
        XCTAssertEqual(TeleprompterA.footerState(isPaused: state.isPlaybackPaused, isPausedForDictation: false), "Reading",
                       file: file, line: line)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), stale + span,
                       "\(row): \"Reading\" froze at \(stale) ms for \(span) ms", file: file, line: line)
    }

    /// FORWARD JUMP: Pause showed the daemon's real position after the clock had been stuck behind it.
    private func assertForwardJumpRow(_ row: String, shown stale: Int, real: Int, total: Int,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let (state, sent) = makeState()
        state.handleEvent(chunkEdge(chunkMs: stale, total: total))
        now += Double(stale) / 1000
        play(state, from: stale, to: real, chunkStart: stale, chunkMs: total - stale, total: total)
        let shown = state.playbackElapsedMilliseconds()
        XCTAssertLessThanOrEqual(abs(shown - real), 300, "\(row): showed \(shown) ms while the audio was at \(real) ms",
                                 file: file, line: line)
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last { $0["cmd"] as? String == "pause" }?["playback_elapsed_ms"] as? Int, shown, file: file, line: line)
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-2", "generation": 2,
                           "offset_ms": real, "chunk_offset_ms": real - stale, "pause_owner": "user"])
        XCTAssertLessThanOrEqual(abs(state.playbackElapsedMilliseconds() - shown), 300,
                                 "\(row): Pause jumped the clock \(shown) → \(state.playbackElapsedMilliseconds())", file: file, line: line)
    }

    /// TRANSITION REWIND: an edge of the same read, lower, with no re-anchor, ran the clock (and highlight) back.
    private func assertTransitionRewindRow(_ row: String, at shownMs: Int, staleEdge: Int, total: Int,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let (state, _) = makeState()
        state.handleEvent(chunkEdge(chunkMs: total, total: total))
        now += Double(shownMs) / 1000
        // The daemon reports its player (4 Hz) before the stale edge arrives.
        state.handleEvent(position(shownMs, chunkStart: 0, chunkMs: total, total: total, playbackID: "p-1"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), shownMs, file: file, line: line)
        state.handleEvent(chunkEdge(offset: staleEdge, chunkMs: total, total: total))
        XCTAssertGreaterThanOrEqual(state.playbackElapsedMilliseconds(), shownMs,
                                    "\(row): the clock ran back \(shownMs) → \(state.playbackElapsedMilliseconds())", file: file, line: line)
        now += 0.5
        XCTAssertGreaterThanOrEqual(state.playbackElapsedMilliseconds(), shownMs + 500, file: file, line: line)
    }

    // MARK: - Frozen label (k04-49, k04-58, k06-22, k07-64)

    /// k04-49: "Reading · 1×" frozen at 0:09 / 0:59 so far, "scrub." highlighted 666.1 → 676.4 (≈10 s).
    func testK04_49_readingFrozenAt0m09For10s() { assertFrozenLabelRow("k04-49", frozenAt: 9000, forMs: 10_000, total: 59_000) }
    /// k04-58: "Reading · 1×" frozen at 0:53 after the resume, knob unmoved 683.7 → 692.4.
    func testK04_58_readingFrozenAgainAt0m53() { assertFrozenLabelRow("k04-58", frozenAt: 53_000, forMs: 7000, total: 66_000) }
    /// k06-22: "Reading · 1×" + pause icon frozen at 0:06 between toggles, 979.9 → 987.9.
    func testK06_22_readingFrozenAt0m06BetweenToggles() { assertFrozenLabelRow("k06-22", frozenAt: 6000, forMs: 8000, total: 13_000 + 8000) }
    /// k07-64: "Reading" frozen at 0:49 on "going." 1663.15 → 1680.9 (17.7 s) while "so far" grows 1:04 → 1:09.
    func testK07_64_readingFrozenAt0m49For17s() { assertFrozenLabelRow("k07-64", frozenAt: 49_000, forMs: 17_700, total: 69_000) }

    // MARK: - Forward jump on Pause (k03-45, k04-54, k04-66, k07-46, k07-61)

    /// k03-45: 0:09 / 0:59 so far (487.3) → Paused 0:43 (487.7).
    func testK03_45_pauseJumped0m09To0m43() { assertForwardJumpRow("k03-45", shown: 9000, real: 43_000, total: 59_000) }
    /// k04-54: 0:09 "scrub." (676.40) → Paused 0:43 (676.55).
    func testK04_54_pauseJumped0m09To0m43Again() { assertForwardJumpRow("k04-54", shown: 9000, real: 43_000, total: 59_000) }
    /// k04-66: short read 0:01 "a" / 0:07 so far → Paused 0:04 "antigravity." / 0:10.
    func testK04_66_shortReadPauseJumped0m01To0m04() { assertForwardJumpRow("k04-66", shown: 1000, real: 4000, total: 10_000) }
    /// k07-46: 0:10 / 1:04 so far, "and" → Paused 0:41 / 1:04, "and" still highlighted.
    func testK07_46_pauseJumped0m10To0m41() { assertForwardJumpRow("k07-46", shown: 10_000, real: 41_000, total: 64_000) }
    /// k07-61: 0:10 → Paused 0:38 (1658.1); reopened at 0:49.
    func testK07_61_pauseJumped0m10To0m38() { assertForwardJumpRow("k07-61", shown: 10_000, real: 38_000, total: 64_000) }

    // MARK: - Resume (k04-57)

    /// k04-57: 0:43 (681.2) → 0:53 "Reading" right after Play. Resume lands where it paused and runs on.
    func testK04_57_resumeShowed0m53ForA0m43Pause() {
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

    // MARK: - Transition rewind (k03-21, k04-63, k07-29)

    /// k03-21: 0:02 / 0:13 so far, "the" → 0:01, title highlighted, with no click or seek target.
    func testK03_21_clockRewound0m02To0m01WithoutASeek() { assertTransitionRewindRow("k03-21", at: 2000, staleEdge: 0, total: 13_000) }
    /// k04-63: short read 0:02 "narration"/"with" → 0:01 "fixes:" while "Reading · 1×".
    func testK04_63_shortReadClockRewound0m02To0m01() { assertTransitionRewindRow("k04-63", at: 2000, staleEdge: 1000, total: 7000) }
    /// k07-29: wing/panel 0:08 "was" → 0:04 "itself:"; also 0:09 → 0:08 earlier in the read.
    func testK07_29_clockRewound0m08To0m04() { assertTransitionRewindRow("k07-29", at: 8000, staleEdge: 4000, total: 64_000) }

    /// A real seek still moves the clock back (it carries reanchor "seek").
    func testASeekStillMovesTheClockBack() {
        let (state, _) = makeState()
        state.handleEvent(chunkEdge(chunkMs: 20_000, total: 20_000))
        now += 8
        state.handleEvent(chunkEdge(offset: 2000, chunkMs: 20_000, total: 20_000, generation: 2, reanchor: "seek"))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 2000)
    }

    // MARK: - Completion (k06-31)

    /// k06-31: "0:10 / 0:13" (1011.483) → "0:06 / 0:06" (1011.617) at completion.
    func testK06_31_completionDroppedElapsedAndTotalTo0m06() {
        let (state, _) = makeState()
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
