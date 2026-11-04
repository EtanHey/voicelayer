@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

@MainActor
final class F5PauseConformanceTests: XCTestCase {
    struct Row: Decodable {
        let initial: String
        let press: Int
        let manual: Bool
        let stopped: Bool
        let outcome: String
        let queued: Int
        let gesture: String
        let takes: Int?
        let ending: Int?
        let manualBefore: Bool?
    }

    func testN6TakeSetKeepsF5ReadParkedUntilEveryTakeSettles() async throws {
        for manual in [false, true] {
            let state = VoiceState()
            state.isConnected = true
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            let router = VoiceBarCommandRouter(voiceState: state)
            state.selectionTextCaptureHandler = { $0(.completed("One two")) }
            state.speakSelection()
            let requestID = try XCTUnwrap(commands.last?["id"] as? String)
            state.handleEvent(["type": "ack", "command": "speak_text", "id": requestID, "outcome": "accept"])
            commands.removeAll()
            let speech: [String: Any] = ["type": "state", "state": "speaking", "text": "One two",
                                        "playback_id": "read", "generation": 1, "duration_ms": 4000, "request_id": requestID]
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
            await drainMainQueue()
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

    func testTLCF5CaptureProjectionDrivesRealRouterAndState() async throws {
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
            state.selectionTextCaptureHandler = { $0(.completed("One two")) }
            state.speakSelection()
            let requestID = try XCTUnwrap(commands.last?["id"] as? String)
            state.handleEvent(["type": "ack", "command": "speak_text", "id": requestID, "outcome": "accept"])
            commands.removeAll()
            let manualBefore = row.initial == "paused" || row.manualBefore == true
            let press = row.initial == "preparing" ? 0 : min(row.press * 1000, 4000)
            let offset = min(press / 2000 * 2000, 4000)
            let speaking: [String: Any] = ["type": "state", "state": "speaking", "text": "One two",
                                           "duration_ms": 4000, "playback_id": "model-read", "generation": 1,
                                           "request_id": requestID]
            if row.initial == "preparing" {
                state.handleEvent(["type": "state", "state": "speaking", "text": "One two", "request_id": requestID,
                                   "long_read": ["id": "model-read", "chunk_index": 0, "chunk_count": 1,
                                                 "chunk_start_ms": 0, "preparing": true, "text": "One two"]])
            } else { state.handleEvent(speaking) }
            state.handleEvent(["type": "read_queue", "count": row.queued, "current_request_id": requestID])
            clock += Double(press) / 1000
            var paused: [String: Any] = ["type": "playback_state", "state": "paused", "playback_id": "model-read",
                                         "generation": 2, "offset_ms": offset, "chunk_offset_ms": offset,
                                         "pause_owner": manualBefore ? "user" : "f5"]
            if row.initial == "preparing" {
                paused["long_read"] = ["id": "model-read", "chunk_index": 0, "chunk_count": 1,
                                       "chunk_start_ms": 0, "preparing": true, "text": "One two"]
            }
            if manualBefore {
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
            var takeIDs = [try XCTUnwrap(record["take_id"] as? String)]
            if row.takes == 2 {
                // Release only A's microphone; A is still processing when F5 starts B (N6).
                router.handleHotkeyHoldEnd(holdDuration: 1)
                if row.gesture != "hold" { router.handleHotkeySingleTap() }
                state.pendingIntent = nil
                state.handleEvent(["type": "state", "state": "transcribing", "source": "recording",
                                   "recording_jobs": [["take_id": takeIDs[0], "kind": "live", "phase": "processing"]],
                                   "mic_take_id": NSNull()])
                XCTAssertTrue(state.canRecordDuringProcessing, "N6 row \(index)")
                if row.gesture == "tap" { router.handleHotkeySingleTap() }
                else { router.handleHotkeyHoldStart() }
                if row.gesture == "double" { router.handleHotkeyDoubleTap() }
                XCTAssertEqual(commands.last?["cmd"] as? String, "record", "N6 row \(index)")
                takeIDs.append(try XCTUnwrap(commands.last?["take_id"] as? String))
                XCTAssertNotEqual(takeIDs[0], takeIDs[1])
                state.pendingIntent = nil
            }
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
            if takeIDs.count == 2 {
                let remaining = takeIDs[1 - (row.ending ?? 0)]
                state.handleEvent(["type": "state", "state": "transcribing", "source": "recording",
                                   "recording_jobs": [["take_id": remaining, "kind": "live", "phase": "processing"]],
                                   "mic_take_id": NSNull()])
                XCTAssertEqual(state.mode, .transcribing, "partial settlement row \(index)")
                XCTAssertFalse(commands.contains { ["resume", "cancel"].contains($0["cmd"] as? String ?? "") })
            }
            state.handleEvent(["type": "state", "state": "idle", "source": "recording",
                               "recording_jobs": [], "mic_take_id": NSNull()])
            await drainMainQueue()
            XCTAssertFalse(commands.contains { $0["cmd"] as? String == "resume" }, "only daemon settles row \(index)")
            let manual = manualBefore || row.manual
            if !row.stopped && !manual {
                var resumed = speaking
                resumed["generation"] = 3
                resumed["playback_offset_ms"] = offset
                state.handleEvent(resumed)
                state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "model-read", "generation": 3])
                XCTAssertEqual(state.mode, .speaking, "native resumed projection row \(index)")
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

    func testRealDaemonSettlementFramesProjectResumedReadToSpeaking() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOICELAYER_F5_DAEMON_WIRE"] else {
            throw XCTSkip("Run formal/speech-queue/check.sh for paired daemon frames")
        }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
        var resumedCount = 0
        for (index, row) in rows.enumerated() {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.isConnected = true
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed("One two")) }
            state.speakSelection()
            let requestID = try XCTUnwrap(commands.last?["id"] as? String)
            state.handleEvent(["type": "ack", "command": "speak_text", "id": requestID, "outcome": "accept"])
            let frames = try XCTUnwrap(row["events"] as? [[String: Any]])
            var beganPause = false
            for var event in frames {
                if !beganPause, event["type"] as? String == "playback_state", event["state"] as? String == "paused" {
                    // The first command leg supplies this local intent before its daemon pause reply.
                    // Preparing has no playback ID yet; pendingPauseEpoch is its ownership proof.
                    if event["pause_owner"] as? String == "user" { state.togglePlaybackPause() }
                    else { state.record(pressToTalk: true); state.pendingIntent = nil }
                    beganPause = true
                }
                // Bind the daemon's symbolic selection to this native submission, as in the command leg.
                if event["request_id"] as? String == row["requestID"] as? String { event["request_id"] = requestID }
                if event["current_request_id"] as? String == row["requestID"] as? String { event["current_request_id"] = requestID }
                if ["state", "read_queue", "playback_state", "playback_outcome", "subtitle", "error"].contains(event["type"] as? String ?? "") {
                    state.handleEvent(event)
                }
            }
            await drainMainQueue()
            if row["resumes"] as? Bool == true {
                XCTAssertEqual(state.mode, .speaking, "native daemon resumed projection row \(index)")
                XCTAssertFalse(state.isPlaybackPaused, "row \(index)")
                XCTAssertEqual(state.teleprompterText, "One two", "row \(index)")
                let resumed = try XCTUnwrap(frames.last { $0["state"] as? String == "resumed" })
                XCTAssertEqual(state.playbackElapsedMilliseconds(), resumed["offset_ms"] as? Int, "row \(index)")
                state.togglePlaybackPause()
                XCTAssertEqual(commands.last?["playback_id"] as? String, resumed["playback_id"] as? String)
                XCTAssertEqual(commands.last?["generation"] as? Int, resumed["generation"] as? Int)
                resumedCount += 1
            }
        }
        XCTAssertGreaterThan(resumedCount, 0)
        print("Projected \(rows.count) real daemon F5 scenarios into native state; \(resumedCount) expected resumes checked")
    }

    /// Wait for the already-enqueued restore, independent of timer resolution or host load.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
