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
        // Pin the capture clock: a real clock measures >= 1 ms on a loaded host, and any
        // measured capture scales the wait to >= 60 s (4x capture + 60 s), hiding the base timeout.
        state.recordingTimingClock = { 1_000 }
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

    func testTranscriptionWaitOutlastsDaemonReturnDeadline() {
        // Daemon: max(120 s, 4x decoded audio) + 15 s grace; decoded <= captured.
        XCTAssertEqual(VoiceState.transcriptionWait(base: .seconds(900), captureDurationMs: nil), .seconds(900))
        XCTAssertEqual(VoiceState.transcriptionWait(base: .seconds(900), captureDurationMs: 30_000), .seconds(900))
        for capturedMs in [342_000, 600_000, 939_040] {
            let daemonDeadline = Duration.milliseconds(max(120_000, capturedMs * 4)) + .seconds(15)
            XCTAssertGreaterThan(
                VoiceState.transcriptionWait(base: .seconds(900), captureDurationMs: capturedMs),
                daemonDeadline,
                "the notch must not give up on a \(capturedMs) ms take before the daemon does"
            )
        }
    }

    @MainActor
    func testLongCaptureScalesTheLiveTranscriptionWait() async throws {
        let state = VoiceState()
        var now: TimeInterval = 1_000
        state.recordingTimingClock = { now }
        state.transcriptionTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        defer { state.setConnectionStatus(false) }
        state.handleEvent([
            "type": "state", "state": "recording", "mode": "ptt", "bar_owned": false,
        ])
        now += 300 // a five-minute capture
        state.handleEvent(["type": "state", "state": "transcribing"])

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.mode, .transcribing, "a long capture must not fall back to the short base wait")
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testDaemonSttAudioScalesTheWaitWhenRecordingStartWasMissed() async throws {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        defer { state.setConnectionStatus(false) }
        // No recording event reached VoiceBar (e.g. it reconnected mid-capture).
        state.handleEvent(["type": "state", "state": "transcribing", "stt_audio_ms": 600_000])

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.mode, .transcribing, "the daemon's decoded length must scale the wait")
        XCTAssertNil(state.errorMessage)
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
