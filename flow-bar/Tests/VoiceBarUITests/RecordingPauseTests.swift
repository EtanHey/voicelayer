@testable import VoiceBarUI
import XCTest

/// Recording pause (Etan, 2026-11-08: "no pause button nor mute. A pause would be fine, so it just doesn't create
/// more audio"). The PTT recording wing gets Pause beside Stop; paused, it shows Resume, a still meter and a
/// frozen recording clock. The daemon owns the audio gate; this side only sends the intent.
final class RecordingPauseTests: XCTestCase {
    private func recordingState(mode: String = "ptt", captureID: Int? = 7) -> (VoiceState, () -> [[String: Any]], (TimeInterval) -> Void) {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        var now: TimeInterval = 100
        state.recordingTimingClock = { now }
        state.sendCommand = { commands.append($0) }
        var event: [String: Any] = ["type": "state", "state": "recording", "mode": mode]
        if let captureID { event["capture_id"] = captureID }
        state.handleEvent(event)
        return (state, { commands }, { now += $0 })
    }

    func testPTTWingOffersPauseThenResume() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "ptt", isPaused: false),
            VoiceBarRecordingPauseControl(iconName: "pause.fill", accessibilityLabel: "Pause recording",
                                          accessibilityHint: "Stop adding audio to this take until you resume",
                                          isSelected: false)
        )
        XCTAssertEqual(
            VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "ptt", isPaused: true),
            VoiceBarRecordingPauseControl(iconName: "play.fill", accessibilityLabel: "Resume recording",
                                          accessibilityHint: "Continue the same take", isSelected: true)
        )
        // VAD takes end on their own silence and keep the Lock slot; nothing else shows Pause.
        XCTAssertNil(VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "vad", isPaused: false))
        XCTAssertNil(VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: nil, isPaused: false))
        XCTAssertNil(VoiceBarPresentation.recordingPauseControl(mode: .transcribing, recordingMode: "ptt", isPaused: false))
    }

    func testPauseTakesTheThirdRecordingSlot() {
        let paused = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording, showsRecordingPause: true))
        let held = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording, showsRecordingHold: true))
        let plain = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording))
        XCTAssertEqual(paused.geometry.leadingWingWidth, held.geometry.leadingWingWidth)
        XCTAssertGreaterThan(paused.geometry.leadingWingWidth, plain.geometry.leadingWingWidth)
    }

    func testPauseSendsACaptureBoundIntentAndResumeContinues() throws {
        let (state, commands, _) = recordingState()
        state.setRecordingPaused(true)
        XCTAssertTrue(state.isRecordingPaused)
        let pause = try XCTUnwrap(commands().last)
        XCTAssertEqual(pause["cmd"] as? String, "set_recording_pause")
        XCTAssertEqual(pause["paused"] as? Bool, true)
        XCTAssertEqual(pause["capture_id"] as? Int, 7)
        // One request in flight at a time, like Lock.
        state.setRecordingPaused(false)
        XCTAssertEqual(commands().count, 1)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(pause["id"] as? String)])
        state.setRecordingPaused(false)
        XCTAssertFalse(state.isRecordingPaused)
        XCTAssertEqual(commands().last?["paused"] as? Bool, false)
        XCTAssertEqual(state.mode, .recording, "resume continues the same take")
    }

    func testRejectedPauseRollsBack() throws {
        let (state, commands, _) = recordingState()
        state.setRecordingPaused(true)
        let id = try XCTUnwrap(commands().last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "reject",
                           "id": id, "reason": "pause needs push-to-talk"])
        XCTAssertFalse(state.isRecordingPaused)
    }

    func testVADRecordingCannotPause() {
        let (state, commands, _) = recordingState(mode: "vad")
        state.setRecordingPaused(true)
        XCTAssertFalse(state.isRecordingPaused)
        XCTAssertTrue(commands().isEmpty)
    }

    func testRecordingClockFreezesWhilePaused() throws {
        let (state, commands, advance) = recordingState()
        advance(12.4)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 12_400)
        state.setRecordingPaused(true)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        advance(30)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 12_400, "the timer freezes while paused")
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: state.recordingActiveElapsedMilliseconds()), "0:12")
        state.setRecordingPaused(false)
        advance(2)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 14_400)
    }

    func testPausedMeterIsStill() {
        let (state, _, _) = recordingState()
        state.handleEvent(["type": "audio_level", "rms": 0.6])
        XCTAssertGreaterThan(state.recordingWaveformLevel, 0)
        state.setRecordingPaused(true)
        XCTAssertEqual(state.recordingWaveformLevel, 0)
        XCTAssertEqual(state.recordingWaveformLevels, Array(repeating: 0, count: 7))
    }

    func testRecordingExitClearsPause() {
        let (state, _, advance) = recordingState()
        state.setRecordingPaused(true)
        state.handleEvent(["type": "state", "state": "transcribing"])
        XCTAssertFalse(state.isRecordingPaused)
        advance(5)
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt", "capture_id": 8])
        XCTAssertFalse(state.isRecordingPaused)
        advance(1)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 1_000, "a new take starts its own clock")
    }
}
