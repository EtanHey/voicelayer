@testable import VoiceBarUI
import XCTest

final class VoiceStateTests: XCTestCase {
    func testVoiceAskWaitingIndicatorOnlyFollowsExplicitBlockingEvent() {
        let state = VoiceState()

        state.handleEvent([
            "type": "blocking_question_waiting",
            "waiting": true,
        ])
        XCTAssertTrue(state.isBlockingQuestionWaitingForUser)

        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "plain speech",
        ])
        XCTAssertFalse(state.isBlockingQuestionWaitingForUser)
    }

    func testFinalTranscriptionStoresHistoryTimestampAndAudioDuration() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        state.currentDateProvider = { now }

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "keeps its audio time",
            "duration_ms": 8400,
        ])

        XCTAssertEqual(state.recentHistoryItems.count, 1)
        XCTAssertEqual(state.recentHistoryItems[0].text, "keeps its audio time")
        XCTAssertEqual(state.recentHistoryItems[0].createdAt, now)
        XCTAssertEqual(state.recentHistoryItems[0].audioDurationMs, 8400)
    }

    func testFailedTranscriptionStaysInHistoryAtRecordTimeWithAudioDuration() {
        let started = Date(timeIntervalSince1970: 1_790_000_100)
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        state.currentDateProvider = { started }

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "duration_ms": 42000,
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "",
            "duration_ms": 42000,
        ])

        XCTAssertEqual(state.recentHistoryItems.count, 1)
        XCTAssertEqual(state.recentHistoryItems[0].createdAt, started)
        XCTAssertEqual(state.recentHistoryItems[0].audioDurationMs, 42000)
        XCTAssertTrue(state.recentHistoryItems[0].isFailed)
    }

    func testEditWordInferenceOffersCorrectionWhenOneWordChanges() {
        let offer = VoiceBarPresentation.dictionaryLearningOffer(
            original: "open the domekin dashboard",
            edited: "open the Domica dashboard"
        )

        XCTAssertEqual(offer?.kind, .correction)
        XCTAssertEqual(offer?.heard, "domekin")
        XCTAssertEqual(offer?.written, "Domica")
    }

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
