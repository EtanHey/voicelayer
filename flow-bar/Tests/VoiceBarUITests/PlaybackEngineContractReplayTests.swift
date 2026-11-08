@testable import VoiceBarUI
import XCTest

/// Lane B (2.4), QA 11:47 Row 1 and Row 3: the REAL daemon event stream for a read on its second chunk (starting at
/// 0:30) parked by two voice_asks back to back, then paused (recorded by src/__tests__/playback-engine.test.ts "Row 1"
/// with LANEB_RECORD_STREAM=1), replayed into VoiceState on the same virtual clock. The capture states the recorder
/// broadcasts (mocked in that daemon test) are inserted between each prompt and its restore, as input.ts sends them.
///
/// #818 review: the read's clock is checked for monotonicity ACROSS edges (asks, restores, the pause), per read. Only
/// a seek or replay may move it back; a resume may rewind at most to the start of the word it paused on (the daemon
/// keeps that word's tail, by design). The final Pause is checked against the daemon's own answer.
@MainActor
final class PlaybackEngineContractReplayTests: XCTestCase {
    private var now: TimeInterval = 100
    /// One word of the fixture (words every 2 s): the most a resume may rewind, to the paused word's start.
    private static let oneWordMs = 2000

    private struct Stream {
        let text: String
        let events: [[String: Any]]
    }

    private static func stream() throws -> Stream {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/laneb-row1-ask-over-read-events.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Stream(text: try XCTUnwrap(json["text"] as? String), events: try XCTUnwrap(json["events"] as? [[String: Any]]))
    }

    private static let capture: [[String: Any]] = [
        ["type": "state", "state": "recording", "mode": "vad", "silence_mode": "standard", "bar_owned": false],
        ["type": "state", "state": "transcribing", "stt_audio_ms": 2400],
        ["type": "transcription", "text": "QA answer"],
        ["type": "state", "state": "idle", "source": "recording"],
    ]

    func testEveryRestoredReadReattachesWithThePlayersClockAndTheClockNeverRunsBackwards() throws {
        let stream = try Self.stream()
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }

        var restores: [Int] = []
        // The highest clock the READ has shown so far, kept across every edge (never reset by an ask or a restore).
        var readHigh: Int?
        var readShowing: Bool { state.mode == .speaking && state.statusText == stream.text }
        func checkRead(_ context: String, allowRewind: Int = 0) {
            guard readShowing else { return }
            let clock = state.playbackElapsedMilliseconds()
            if let high = readHigh {
                XCTAssertGreaterThanOrEqual(clock, high - allowRewind, "\(context): the read's clock ran backwards (\(high) → \(clock))")
                // A permitted rewind (to the paused word's start) re-bases the high-water mark; nothing else does.
                readHigh = allowRewind > 0 ? clock : max(high, clock)
            } else {
                readHigh = clock
            }
        }
        var pausedShown: Int?
        for (index, raw) in stream.events.enumerated() {
            var event = raw
            let t = (event.removeValue(forKey: "__t") as? NSNumber)?.doubleValue ?? 0
            // Row 3a: sample at 30 Hz up to this event.
            while state.mode == .speaking, !state.isPlaybackPaused, now + 1.0 / 30 < 100 + t / 1000 {
                now += 1.0 / 30
                checkRead("30 Hz sample at \(now)")
            }
            now = max(now, 100 + t / 1000)
            let type = event["type"] as? String
            if type == "playback_state", event["state"] as? String == "paused", readShowing {
                pausedShown = state.playbackElapsedMilliseconds()
            }
            state.handleEvent(event)
            let reanchor = event["reanchor"] as? String
            if reanchor == "seek" || reanchor == "replay" { readHigh = nil }
            // A resume (and the paused response) may land on the paused word's start: at most one word back.
            let rewind = reanchor == "resume" || reanchor == "resync" || type == "playback_state" ? Self.oneWordMs : 0
            checkRead("after event \(index) (\(type ?? "?") \(event["state"] ?? ""))", allowRewind: rewind)
            // The prompt's idle hands the pill to the capture.
            if type == "state", event["state"] as? String == "idle", event["source"] == nil {
                for step in Self.capture { state.handleEvent(step) }
            }
            if type == "playback_state", event["state"] as? String == "resumed" {
                restores.append(index)
                let edge = stream.events[..<index].last { $0["state"] as? String == "speaking" && $0["text"] as? String == stream.text }
                let offset = try XCTUnwrap((edge?["playback_offset_ms"] as? NSNumber)?.intValue)
                // Row 1: the read is back on screen after EVERY ask, with its controls and the player's clock.
                XCTAssertEqual(state.mode, .speaking, "restore \(restores.count): the read UI is attached")
                XCTAssertEqual(state.statusText, stream.text, "restore \(restores.count)")
                XCTAssertFalse(state.isPlaybackPaused, "restore \(restores.count)")
                XCTAssertTrue(state.showsPlaybackClock, "restore \(restores.count)")
                XCTAssertEqual(state.playbackElapsedMilliseconds(), offset,
                               "restore \(restores.count): the clock is the player's position (0:40/0:42), never 0:10")
                XCTAssertGreaterThanOrEqual(offset, 30_000, "never a chunk-local clock")
            }
            if type == "playback_state", event["state"] as? String == "paused" {
                // Row 3b, response-driven: the daemon's answer is where the clock now stands; it never jumps forward
                // past what was shown, and steps back at most to the paused word's start.
                let answer = try XCTUnwrap((event["offset_ms"] as? NSNumber)?.intValue)
                XCTAssertTrue(state.isPlaybackPaused)
                XCTAssertEqual(state.playbackElapsedMilliseconds(), answer, "the paused clock is the daemon's word start")
                let shown = try XCTUnwrap(pausedShown)
                XCTAssertLessThanOrEqual(answer, shown, "Pause moved the clock forward (\(shown) → \(answer))")
                XCTAssertGreaterThanOrEqual(answer, shown - Self.oneWordMs, "Pause rewound more than a word (\(shown) → \(answer))")
            }
        }
        XCTAssertEqual(restores.count, 2, "two asks, two restores")
        XCTAssertNotNil(pausedShown, "the stream ends with the daemon's answer to a Pause")
        XCTAssertTrue(sent.allSatisfy { $0["cmd"] as? String != "resync_playback" }, "no edge was lost, so no resync")
    }
}
