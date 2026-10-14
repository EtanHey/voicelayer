@testable import VoiceBarUI
import XCTest

final class SpeechRoundTwoTests: XCTestCase {
    func testMeaningfulHealthSettlesOnceAndIdenticalHealthDoesNotLoop() {
        let state = VoiceState()
        var settled = 0
        state.sendCommand = { _ in }
        state.onSpeechSettled = { settled += 1; state.refreshModelsSettingsStatus() }
        state.setConnectionStatus(true)
        let health = SpeechReviewRegressionTests.health()
        state.handleEvent(health)
        XCTAssertEqual(settled, 1, "nil to parsed controls must repaint once")
        state.handleEvent(health)
        XCTAssertEqual(settled, 1, "the root's onAppear health must not start a loop")
        var controls = SpeechSettingsTests.controls()
        var profiles = controls["profiles"] as! [String: [String: Any]]
        profiles["short"]?["last_first_audio_ms"] = 1200
        controls["profiles"] = profiles
        state.handleEvent(SpeechReviewRegressionTests.health(controls))
        XCTAssertEqual(settled, 2, "new measured latency must repaint once")
        state.handleEvent(SpeechReviewRegressionTests.health(controls))
        XCTAssertEqual(settled, 2)
    }
    func testReconnectHealthRepaintsSpeechFormOnce() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent(SpeechReviewRegressionTests.health())
        state.setConnectionStatus(false)
        state.setConnectionStatus(true)
        XCTAssertNil(state.speechControls)
        var settled = 0
        state.onSpeechSettled = { settled += 1 }
        state.handleEvent(SpeechReviewRegressionTests.health())
        XCTAssertNotNil(state.speechControls)
        XCTAssertEqual(settled, 1)
    }
    func testModelsRefreshAndWhisperLoadDoNotBlockPreview() throws {
        for loading in [false, true] {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.setConnectionStatus(true)
            state.handleEvent(SpeechReviewRegressionTests.health())
            if loading { state.setWhisperResidency(.loaded) } else { state.refreshModelsSettingsStatus() }
            XCTAssertTrue(state.modelsSettingsState.isBusy)
            commands = []
            XCTAssertNil(state.speechBusyReason)
            state.previewTTSProfile(.short)
            XCTAssertEqual(commands.last?["cmd"] as? String, "preview_tts_profile")
            XCTAssertNotNil(state.speechPending["preview"])
        }
    }
    func testPreviewAdmissionFailureShowsNoticeForCaptureQueueAndDisconnect() {
        for reason in ["recording", "transcribing", "queue", "disconnected", "pending"] {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.setConnectionStatus(true)
            state.handleEvent(SpeechReviewRegressionTests.health())
            switch reason {
            case "recording": state.mode = .recording
            case "transcribing": state.mode = .transcribing
            case "queue": state.queueDepth = 1
            case "disconnected": state.setConnectionStatus(false)
            default: state.setTTSSetting("short.rate", .string("+20%")); commands = []
            }
            state.previewTTSProfile(.long)
            XCTAssertTrue(commands.isEmpty, reason)
            XCTAssertNotNil(state.speechNotice, reason)
        }
    }
    func testHealthCaptureAndDaemonPreviewDriveSpeechBusyWithoutModels() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent(SpeechReviewRegressionTests.health(idle: false))
        XCTAssertEqual(state.speechBusyReason, "Recording in progress")
        var controls = SpeechSettingsTests.controls()
        controls["preview_active"] = true
        state.handleEvent(SpeechReviewRegressionTests.health(controls))
        XCTAssertEqual(state.speechBusyReason, "Preview in progress…")
    }
    func testSpeakingReplacesPreparationNoticeWithOnePreviewStatus() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.setConnectionStatus(true)
        state.handleEvent(SpeechReviewRegressionTests.health())
        state.previewTTSProfile(.short)
        XCTAssertEqual(state.speechNotice, "Preparing preview…")
        state.mode = .speaking
        XCTAssertNil(state.speechNotice)
        XCTAssertEqual(state.speechBusyReason, "Speaking…")
    }
    func testRejectedPreviewAckAppliesInactiveDaemonControls() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(SpeechReviewRegressionTests.health())
        state.previewTTSProfile(.short)
        let id = try XCTUnwrap(commands.last?["id"] as? String)
        var controls = SpeechSettingsTests.controls()
        controls["preview_active"] = true
        state.handleEvent(SpeechReviewRegressionTests.health(controls))
        controls["preview_active"] = false
        state.handleEvent(["type": "ack", "command": "preview_tts_profile", "id": id, "outcome": "reject",
                           "reason": "synthesis failed", "tts_controls": controls])
        XCTAssertEqual(state.speechControls?.previewActive, false)
        XCTAssertNil(state.speechPending["preview"])
    }

}
