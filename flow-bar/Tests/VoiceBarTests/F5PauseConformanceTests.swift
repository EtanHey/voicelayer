@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class F5PauseConformanceTests: XCTestCase {
    struct Row: Decodable {
        let initial: String
        let press: Int
        let manual: Bool
        let stopped: Bool
        let outcome: String
        let queued: Int
        let gesture: String
    }

    func testN6TakeSetKeepsF5ReadParkedUntilEveryTakeSettles() throws {
        for manual in [false, true] {
            let state = VoiceState()
            state.isConnected = true
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            let router = VoiceBarCommandRouter(voiceState: state)
            let speech: [String: Any] = ["type": "state", "state": "speaking", "text": "One two",
                                        "playback_id": "read", "generation": 1, "duration_ms": 4000]
            state.handleEvent(speech)
            router.handleHotkeyHoldStart()
            let a = try XCTUnwrap(commands.last?["take_id"] as? String)
            state.pendingIntent = nil
            var pause: [String: Any] = ["type": "playback_state", "state": "paused", "playback_id": "read",
                                       "generation": 2, "offset_ms": 2000, "chunk_offset_ms": 2000, "pause_owner": "f5"]
            state.handleEvent(pause)
            router.handleHotkeyHoldEnd(holdDuration: 1)
            state.pendingIntent = nil
            state.handleEvent(["type": "state", "state": "transcribing", "source": "recording",
                               "recording_jobs": [["take_id": a, "kind": "live", "phase": "processing"]], "mic_take_id": NSNull()])
            XCTAssertTrue(state.canRecordDuringProcessing)
            router.handleHotkeyHoldStart()
            let b = try XCTUnwrap(commands.last?["take_id"] as? String)
            XCTAssertNotEqual(a, b)
            XCTAssertEqual(commands.last?["cmd"] as? String, "record")
            state.pendingIntent = nil
            if manual {
                state.pauseSpeechDuringCapture()
                XCTAssertEqual(commands.last?["cmd"] as? String, "pause")
                pause["pause_owner"] = "user"
                state.handleEvent(pause)
            }
            state.handleEvent(["type": "state", "state": "transcribing", "source": "recording",
                               "recording_jobs": [["take_id": b, "kind": "live", "phase": "processing"]], "mic_take_id": NSNull()])
            XCTAssertEqual(state.mode, .transcribing)
            XCTAssertFalse(commands.contains { ["resume", "cancel"].contains($0["cmd"] as? String ?? "") })
            state.handleEvent(["type": "state", "state": "idle", "source": "recording", "recording_jobs": [], "mic_take_id": NSNull()])
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            if manual { XCTAssertTrue(state.isPlaybackPaused) }
            else {
                XCTAssertFalse(state.isPlaybackPaused)
                var resumed = speech
                resumed["generation"] = 3
                resumed["playback_offset_ms"] = 2000
                state.handleEvent(resumed)
            }
            let count = commands.count
            router.handleHotkeyHoldEnd(holdDuration: 10)
            state.handleEvent(["type": "state", "state": "idle", "source": "recording", "recording_jobs": [], "mic_take_id": NSNull()])
            XCTAssertEqual(commands.count, count)
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertEqual(state.isPlaybackPaused, manual)
        }
    }

    func testTLCF5CaptureProjectionDrivesRealRouterAndState() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICELAYER_F5_CASES"],
              let wire = ProcessInfo.processInfo.environment["VOICELAYER_F5_WIRE"] else {
            throw XCTSkip("Run formal/speech-queue/check.sh for TLC-generated F5 scenarios")
        }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var output: [[[String: Any]]] = []
        for (index, row) in rows.enumerated() {
            var clock = 100.0
            let state = VoiceState(playbackAmplitudeClock: { clock })
            state.isConnected = true
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            let router = VoiceBarCommandRouter(voiceState: state)
            let press = min(row.press * 1000, 4000)
            let offset = min(press / 2000 * 2000, 4000)
            let speaking: [String: Any] = ["type": "state", "state": "speaking", "text": "One two",
                                           "duration_ms": 4000, "playback_id": "model-read", "generation": 1]
            state.handleEvent(speaking)
            clock += Double(press) / 1000
            var paused: [String: Any] = ["type": "playback_state", "state": "paused", "playback_id": "model-read",
                                         "generation": 2, "offset_ms": offset, "chunk_offset_ms": offset,
                                         "pause_owner": row.initial == "paused" ? "user" : "f5"]
            if row.initial == "paused" {
                state.togglePlaybackPause()
                state.handleEvent(paused)
            }
            if row.gesture == "tap" { router.handleHotkeySingleTap() }
            else { router.handleHotkeyHoldStart() }
            if row.gesture == "double" { router.handleHotkeyDoubleTap() }
            XCTAssertEqual(commands.last?["cmd"] as? String, "record", "row \(index)")
            let record = try XCTUnwrap(commands.last)
            XCTAssertNotNil(record["take_id"] as? String)
            state.pendingIntent = nil
            state.handleEvent(paused)
            if row.manual {
                XCTAssertTrue(state.isF5SpeechPausedDuringCapture, "row \(index)")
                state.pauseSpeechDuringCapture()
                XCTAssertEqual(commands.last?["cmd"] as? String, "pause")
                paused["pause_owner"] = "user"
                state.handleEvent(paused)
            }
            if row.stopped { state.stopSpeechDuringCapture() }
            if ["pasted", "empty"].contains(row.outcome) {
                if row.gesture == "hold" { router.handleHotkeyHoldEnd(holdDuration: 1) }
                else {
                    if row.gesture == "double" { router.handleHotkeyHoldEnd(holdDuration: 1) }
                    router.handleHotkeySingleTap()
                }
                state.mode = .transcribing
            }
            state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            XCTAssertFalse(commands.contains { $0["cmd"] as? String == "resume" }, "only daemon settles row \(index)")
            let manual = row.initial == "paused" || row.manual
            if !row.stopped && !manual {
                var resumed = speaking
                resumed["generation"] = 3
                resumed["playback_offset_ms"] = offset
                state.handleEvent(resumed)
            }
            let count = commands.count
            // Every outcome, including timeout/failure/cancel, can settle while F5 is still down.
            router.handleHotkeyHoldEnd(holdDuration: 20)
            state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
            XCTAssertEqual(commands.count, count, "post-settlement key-up row \(index)")
            if !row.stopped {
                XCTAssertEqual(state.mode, .speaking, "row \(index)")
                XCTAssertEqual(state.isPlaybackPaused, manual, "row \(index)")
                XCTAssertEqual(state.playbackElapsedMilliseconds(), offset, "row \(index)")
            }
            output.append(commands)
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: wire))
        print("Replayed \(rows.count) TLC F5 scenarios through real VoiceBarCommandRouter/VoiceState; wrote native commands")
    }
}
