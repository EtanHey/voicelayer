@testable import VoiceBarUI
import XCTest

/// Reported 2026-11-08: recording needed a Pause action that stops accumulating audio.
/// Show Pause beside Stop, and Resume with a still meter and a
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
            VoiceBarRecordingPauseControl(iconName: "mic.fill", accessibilityLabel: "Mute microphone",
                                          accessibilityHint: "Mute microphone", isSelected: false)
        )
        XCTAssertEqual(
            VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "ptt", isPaused: true),
            VoiceBarRecordingPauseControl(iconName: "mic.slash.fill", accessibilityLabel: "Unmute microphone",
                                          accessibilityHint: "Unmute microphone", isSelected: true)
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
        // C7-W: the time/meter wing (102 pt) is already wider than three controls (99.5 pt), so the third slot no
        // longer widens the band; it still fits inside it.
        XCTAssertGreaterThanOrEqual(paused.geometry.leadingWingWidth, plain.geometry.leadingWingWidth)
        XCTAssertGreaterThanOrEqual(paused.geometry.leadingWingWidth, VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl)
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

    /// Round 2 (Codex P2): the daemon never paused, so a refused Pause must leave its round-trip in the clock.
    func testRejectedPauseKeepsTheRoundTripInTheClock() throws {
        let (state, commands, advance) = recordingState()
        advance(10)
        state.setRecordingPaused(true)
        advance(3)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 10_000, "optimistically frozen")
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "reject",
                           "id": try XCTUnwrap(commands().last?["id"] as? String), "reason": "pause needs push-to-talk"])
        XCTAssertFalse(state.isRecordingPaused)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 13_000)
        advance(2)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 15_000)
    }

    /// A refused Resume leaves the take paused exactly where it froze.
    func testRejectedResumeRefreezesAtTheOriginalPause() throws {
        let (state, commands, advance) = recordingState()
        advance(10)
        state.setRecordingPaused(true)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        advance(5)
        state.setRecordingPaused(false)
        advance(2)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "noop",
                           "id": try XCTUnwrap(commands().last?["id"] as? String), "reason": "stale capture"])
        XCTAssertTrue(state.isRecordingPaused)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 10_000)
        advance(4)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 10_000)
        // The daemon is still paused, so a later Resume is accepted and counts only time after it.
        state.setRecordingPaused(false)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        advance(1)
        XCTAssertEqual(state.recordingActiveElapsedMilliseconds(), 11_000)
    }

    /// #808 reads this clock on every tick; a sampled sequence is monotonic, frozen while paused, and resets per take.
    func testElapsedClockIsTheSingleTickSource() throws {
        let (state, commands, advance) = recordingState()
        let tick: () -> Int = state.recordingActiveElapsedMilliseconds
        var samples: [Int] = []
        for _ in 0 ..< 4 { advance(0.25); samples.append(tick()) }
        state.setRecordingPaused(true)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        for _ in 0 ..< 4 { advance(0.25); samples.append(tick()) }
        state.setRecordingPaused(false)
        for _ in 0 ..< 2 { advance(0.25); samples.append(tick()) }
        XCTAssertEqual(samples, [250, 500, 750, 1_000, 1_000, 1_000, 1_000, 1_000, 1_250, 1_500])
    }

    /// A take whose `recording` event carries no capture id never sends the previous take's id.
    func testNextTakeDoesNotInheritTheCaptureID() throws {
        let (state, commands, _) = recordingState(captureID: 7)
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        state.setRecordingPaused(true)
        XCTAssertNil(try XCTUnwrap(commands().last)["capture_id"])
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

    /// N1's wing time and the Pause spans run on one injected clock (`recordingTimingClock`): the time stands
    /// still while paused and resumes from where it stopped.
    func testWingTimeStandsStillWhilePaused() throws {
        let (state, commands, advance) = recordingState()
        advance(1)
        state.handleEvent(["type": "audio_level", "rms": 0.2]) // capture opens: the wing's 0:00
        XCTAssertTrue(state.isRecordingCaptureOpen)
        advance(5)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 5_000)
        state.setRecordingPaused(true)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        advance(30)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 5_000, "the wing time stands still while paused")
        state.setRecordingPaused(false)
        advance(2)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 7_000)
    }

    /// A PTT take can be paused between its `recording` event and its first frame; that pause never eats time
    /// the wing has not counted yet.
    func testPauseBeforeCaptureOpensNeverEatsWingTime() throws {
        let (state, commands, advance) = recordingState()
        state.setRecordingPaused(true)
        state.handleEvent(["type": "ack", "command": "set_recording_pause", "outcome": "accept",
                           "id": try XCTUnwrap(commands().last?["id"] as? String)])
        advance(2)
        state.handleEvent(["type": "audio_level", "rms": 0.2])
        XCTAssertTrue(state.isRecordingCaptureOpen)
        advance(3)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0, "still paused since before the open")
        state.setRecordingPaused(false)
        advance(4)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 4_000)
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
