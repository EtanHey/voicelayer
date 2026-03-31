@testable import VoiceBar
import XCTest

final class VoiceStatePasteTests: XCTestCase {
    func testRecordSetsRecordingModeBeforeSendingCommand() {
        let state = VoiceState()
        var modeObservedInsideSend: VoiceMode?
        var callbackModes: [VoiceMode] = []

        state.sendCommand = { _ in
            modeObservedInsideSend = state.mode
        }
        state.onModeChange = { mode in
            callbackModes.append(mode)
        }

        state.record()

        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(modeObservedInsideSend, .recording)
        XCTAssertEqual(callbackModes, [.recording])
    }

    func testSnoozeMovesVoiceStateToDisconnected() {
        let state = VoiceState()

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
    }

    func testUnsnoozeReturnsVoiceStateToIdle() {
        let state = VoiceState()
        state.snooze()

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
    }

    func testSnoozeClearsActiveRecordingAudioLevel() throws {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.5)
        _ = try XCTUnwrap(state.audioLevel)

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
        XCTAssertNil(state.audioLevel)
    }

    func testLocalRecordingLevelOverridesSocketLevelWhileRecording() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.15,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.72, accuracy: 0.001)
    }

    func testLocalRecordingLevelIgnoredOutsideRecordingMode() {
        let state = VoiceState()
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.24,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.24, accuracy: 0.001)
    }

    func testStopClearsLocalRecordingLevel() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.72)

        state.cancel()

        XCTAssertNil(state.audioLevel)
    }

    func testBarInitiatedTranscribingIgnoresStaleIdleUntilTranscriptionArrives() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        XCTAssertEqual(state.mode, .transcribing)
    }

    func testRepasteUsesStoredTranscript() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "test capture from codex",
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["test capture from codex"])
    }

    func testRepasteWaitsForMenuFocusToSettle() {
        XCTAssertGreaterThan(VoicePastePlan.repaste.activationDelay, 0)
        XCTAssertEqual(VoicePastePlan.autoPaste.activationDelay, 0)
    }

    func testRecentTranscriptionsAreMostRecentFirst() {
        let state = VoiceState()

        state.handleEvent([
            "type": "transcription",
            "text": "first note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "second note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "third note",
        ])

        XCTAssertEqual(state.recentTranscriptions, [
            "third note",
            "second note",
            "first note",
        ])
    }
}
