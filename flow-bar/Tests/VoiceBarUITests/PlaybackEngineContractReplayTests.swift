@testable import VoiceBarUI
import XCTest

/// Lane B (2.4), QA 11:47 Row 1 and Row 3: the REAL daemon event stream for a read on its second chunk (starting at
/// 0:30) parked by two voice_asks back to back (recorded by src/__tests__/playback-engine.test.ts "Row 1" with
/// LANEB_RECORD_STREAM=1), replayed into VoiceState on the same virtual clock. The capture states the recorder
/// broadcasts (mocked in that daemon test) are inserted between each prompt and its restore, as input.ts sends them.
@MainActor
final class PlaybackEngineContractReplayTests: XCTestCase {
    private var now: TimeInterval = 100

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
        var lastClock: Int?
        var lastEdge: String?
        for (index, raw) in stream.events.enumerated() {
            var event = raw
            let t = (event.removeValue(forKey: "__t") as? NSNumber)?.doubleValue ?? 0
            // Row 3a: sample the clock at 30 Hz up to this event; between two edges of one read it never decreases.
            while state.mode == .speaking, !state.isPlaybackPaused, now + 1.0 / 30 < 100 + t / 1000 {
                now += 1.0 / 30
                let clock = state.playbackElapsedMilliseconds()
                if let lastClock { XCTAssertGreaterThanOrEqual(clock, lastClock, "clock ran backwards at \(now)") }
                lastClock = clock
            }
            now = max(now, 100 + t / 1000)
            state.handleEvent(event)
            if event["type"] as? String == "state" {
                let edge = "\(event["state"] ?? "")|\(event["playback_offset_ms"] ?? "")|\(event["text"] ?? "")"
                if edge != lastEdge { lastClock = nil; lastEdge = edge }
            }
            // The prompt's idle hands the pill to the capture.
            if event["type"] as? String == "state", event["state"] as? String == "idle", event["source"] == nil {
                for step in Self.capture { state.handleEvent(step) }
                lastClock = nil
            }
            if event["type"] as? String == "playback_state", event["state"] as? String == "resumed" {
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
        }
        XCTAssertEqual(restores.count, 2, "two asks, two restores")

        // Row 3b: a Pause after the second restore sends the clock it shows: no jump.
        now += 2.3
        let shown = state.playbackElapsedMilliseconds()
        state.togglePlaybackPause()
        let pause = try XCTUnwrap(sent.last { $0["cmd"] as? String == "pause" })
        XCTAssertEqual(pause["playback_elapsed_ms"] as? Int, shown)
        XCTAssertEqual(shown, 42_000 + 2_300)
    }
}
