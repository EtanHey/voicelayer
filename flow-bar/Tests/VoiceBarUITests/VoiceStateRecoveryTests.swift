@testable import VoiceBarUI
import XCTest

final class VoiceStateRecoveryTests: XCTestCase {
    func testBarInitiatedEmptyTranscriptionShowsFailure() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "transcription",
            "text": "",
        ])

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Transcription failed")
    }

    func testTranscribingTimesOutAfterThirtySeconds() async {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)

        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Transcription failed")
    }

    func testBarInitiatedTranscribingUsesLongerTimeout() async {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)
        state.barInitiatedTranscriptionTimeout = .seconds(30)

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertNil(state.errorMessage)
    }

    func testBarSafetyTimeoutDoesNotClearPasteTargetDuringTranscribing() async {
        let state = VoiceState()
        state.barInitiatedSafetyTimeout = .milliseconds(20)
        state.barInitiatedTranscriptionTimeout = .seconds(30)
        state.minimumTranscribingDisplayDuration = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "long dictation final transcript",
        ])

        XCTAssertEqual(pastedTexts, ["long dictation final transcript"])
        XCTAssertEqual(state.confirmationText, "long dictation final transcript")
    }

    func testConnectionDropShowsDisconnectedState() {
        let state = VoiceState()
        state.setConnectionStatus(true)

        state.setConnectionStatus(false)

        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.mode, .disconnected)
    }

    func testConnectionDropClearsHotkeyAndPendingRecordStart() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .seconds(30)
        state.setHotkeyEnabled(true)
        state.setHotkeyPhase(.holding)

        state.record(pressToTalk: true)
        state.setConnectionStatus(false)

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .disconnected)
        XCTAssertEqual(state.hotkeyPhase, .idle)
    }

    func testBarInitiatedBrokenMicErrorIsShown() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "error",
            "message": "Microphone input looks silent",
            "recoverable": true,
            "show_during_bar_recording": true,
        ])

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Microphone input looks silent")
    }

    func testErrorEventRequestsPanelLayoutRefresh() {
        assertVoiceStateEventTriggersPanelLayoutRefresh([
            "type": "error",
            "message": "Microphone input looks silent",
            "recoverable": true,
            "show_during_bar_recording": true,
        ])
    }

    func testPressToTalkRecordWithoutAckClearsStuckRecordingPreview() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.setHotkeyEnabled(true)
        state.setHotkeyPhase(.holding)

        state.record(pressToTalk: true)

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.hotkeyPhase, .idle)
        XCTAssertEqual(state.errorMessage, "VoiceLayer is starting")
    }

    func testPressToTalkReleaseBeforeRecordAckKeepsStartupRecoveryActive() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.setHotkeyEnabled(true)
        state.setHotkeyPhase(.holding)

        state.record(pressToTalk: true)
        state.stop()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.hotkeyPhase, .idle)
        XCTAssertEqual(state.errorMessage, "VoiceLayer is starting")
    }

    func testRecordingStateSettlesRecordStartAckTimeout() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertNil(state.errorMessage)
    }

    func testIgnoredBarRecordingErrorDoesNotCancelRecordStartRecovery() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "error",
            "message": "Passive client failed",
            "recoverable": true,
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "VoiceLayer is starting")
    }

    func testTranscriptionStatusEventSurfacesModelWarmup() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription_status",
            "status": "warming",
            "message": "Loading speech model",
        ])

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(state.transcribingStatusText, "Loading speech model")
    }
}
