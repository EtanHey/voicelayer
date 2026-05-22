@testable import VoiceBar
import XCTest

final class VoiceStateTests: XCTestCase {
    func testRecordIntentDoesNotTransitionLocally() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(state.pendingIntent?.command, .record)
        XCTAssertEqual(state.pendingIntent?.id, sentCommand?["id"] as? String)
    }

    func testPressToTalkRecordShowsRecordingImmediately() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        var sentCommand: [String: Any]?
        var modes: [VoiceMode] = []

        state.sendCommand = { command in
            sentCommand = command
        }
        state.onModeChange = { mode in
            modes.append(mode)
        }

        state.record(pressToTalk: true)

        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(modes, [.recording])
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertEqual(sentCommand?["press_to_talk"] as? Bool, true)
    }

    func testBarRecordingUsesLongSafetyTimeout() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record(pressToTalk: true)

        XCTAssertEqual(sentCommand?["timeout_seconds"] as? Int, 3600)
    }

    func testRetranscribeLastCaptureSendsRecoverCommand() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeLastCapture()

        XCTAssertEqual(sentCommand?["cmd"] as? String, "retranscribe_last")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(state.pendingIntent?.command, .retranscribeLast)
        XCTAssertEqual(state.pendingIntent?.id, sentCommand?["id"] as? String)
    }

    func testRecoveredLastCapturePastesFinalTranscription() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "accept",
            "id": id,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "recovered cancelled dictation",
        ])

        XCTAssertEqual(pastedTexts, ["recovered cancelled dictation"])
        XCTAssertEqual(state.latestReusableTranscript, "recovered cancelled dictation")
    }

    func testRejectedRecoveredLastCaptureDoesNotPasteLaterTranscription() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "reject",
            "id": id,
            "reason": "Nothing to transcribe",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "later unrelated transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
        XCTAssertEqual(state.confirmationText, "Nothing to transcribe")
        XCTAssertEqual(state.latestReusableTranscript, "later unrelated transcript")
    }

    func testRetranscribeLastCaptureDebouncesWhileRecoveryIsPending() {
        let state = VoiceState()
        var sentCommands: [[String: Any]] = []

        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeLastCapture()
        let firstPendingIntent = state.pendingIntent
        state.retranscribeLastCapture()

        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertEqual(firstPendingIntent?.command, .retranscribeLast)
        XCTAssertEqual(state.pendingIntent?.id, firstPendingIntent?.id)
    }

    func testRecoveryErrorDoesNotPasteLaterFinalTranscription() {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        state.handleEvent([
            "type": "error",
            "message": "Recovery failed",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "later unrelated transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
        XCTAssertEqual(state.latestReusableTranscript, "later unrelated transcript")
    }

    func testPendingIntentClearsOnMatchingAck() throws {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)

        state.handleEvent([
            "type": "ack",
            "command": "record",
            "outcome": "accept",
            "id": id,
        ])

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .idle)
    }

    func testCancelIntentExitsRecordingLocallyEvenWithoutDaemonAck() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.cancel()

        XCTAssertEqual(state.mode, .idle)
    }

    func testStopShowsTranscribingImmediatelyWhileWaitingForDaemon() async {
        let state = VoiceState()
        var modes: [VoiceMode] = []
        state.onModeChange = { modes.append($0) }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.stop()
        try? await Task.sleep(for: .milliseconds(2200))

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(modes, [.recording, .transcribing])
    }
}
