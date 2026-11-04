@testable import VoiceBarUI
import XCTest

final class VoiceStateRecoveryTests: XCTestCase {
    @MainActor
    func testLiveMCPTranscriptionSurvivesThirtySeconds() async throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        defer { state.setConnectionStatus(false) }
        state.handleEvent([
            "type": "state", "state": "recording", "mode": "ptt", "bar_owned": false,
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription_status", "status": "transcribing", "message": "Transcribing",
        ])

        // Exercise the production deadline, including the daemon's 30-second keepalive cadence.
        try await Task.sleep(for: .seconds(30))
        state.handleEvent(["type": "ping"])
        try await Task.sleep(for: .seconds(1))

        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.mode, .transcribing, "A live MCP take must outlast the old 30-second deadline")
        XCTAssertNil(state.errorMessage)
    }

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

    func testMCPTranscribingStillTimesOutWithoutAResult() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.transcriptionTimeout = .milliseconds(20)
        state.handleEvent([
            "type": "state", "state": "recording", "mode": "ptt", "bar_owned": false,
        ])

        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription_status", "status": "transcribing", "message": "Transcribing",
        ])
        state.handleEvent(["type": "ping"])

        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Transcription timed out while waiting for the result.")
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).errorDetails,
                       "Transcription timed out while waiting for the result.")
    }

    func testMCPTranscribingDisconnectEndsWaitImmediately() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent([
            "type": "state", "state": "recording", "mode": "ptt", "bar_owned": false,
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])

        state.setConnectionStatus(false)

        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.mode, .disconnected)
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

        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

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

        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

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

        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

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
