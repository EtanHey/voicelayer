@testable import VoiceBarUI
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

    func testTranscriptionEventStoresArchivedRecordingPathForHistoryEntry() {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the correction",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Etan confirmed the correction")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
        XCTAssertEqual(state.recentTranscriptions, ["Etan confirmed the correction"])
    }

    func testTranscriptionEventWithRecordingPathNotifiesHistoryArchiveChange() {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var historyArchiveChangeCount = 0
        state.onHistoryArchiveChange = {
            historyArchiveChangeCount += 1
        }

        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the correction",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(historyArchiveChangeCount, 1)
    }

    func testHistoryRetranscribeUpdatesOlderEntryInPlaceWithoutReordering() {
        let latestPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-latest/audio.wav"
        let olderPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-older/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: {
                [
                    RecentTranscriptionEntry(text: "Latest untouched transcript", recordingPath: latestPath),
                    RecentTranscriptionEntry(text: "Ethan old transcript", recordingPath: olderPath),
                ]
            },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "Etan corrected older transcript",
            "recording_path": olderPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Latest untouched transcript",
            "Etan corrected older transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [
            latestPath,
            olderPath,
        ])
    }

    func testHistoryEntryRetranscribeSendsArchivedAudioPathAndUpdatesEntryWithoutPaste() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
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
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)

        XCTAssertEqual(sentCommand?["cmd"] as? String, "retranscribe_recording")
        XCTAssertEqual(sentCommand?["audio_path"] as? String, audioPath)
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        XCTAssertNil(state.pendingIntent)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": id,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
        XCTAssertEqual(state.recentTranscriptions, ["Etan confirmed the corrected transcript"])
        XCTAssertEqual(pastedTexts, [])
    }

    func testHistoryRetranscribeAckStillClearsAfterReplayOverwritesPendingIntent() throws {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        let historyID = try XCTUnwrap(sentCommands.first?["id"] as? String)
        state.replay()
        XCTAssertEqual(state.pendingIntent?.command, .replay)

        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "reject",
            "id": historyID,
            "reason": "Missing archived recording",
        ])
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        let historyCommands = sentCommands.filter { $0["cmd"] as? String == "retranscribe_recording" }
        XCTAssertEqual(historyCommands.count, 2)
        XCTAssertEqual(historyCommands.last?["audio_path"] as? String, secondAudioPath)
        XCTAssertEqual(state.confirmationText, "Missing archived recording")
    }

    func testDeferredHistoryRetranscribeFinalSurvivesNewRecordingState() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0.05
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
    }

    func testDeferredHistoryRetranscribeFinalSurvivesUserRecordStart() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0.05
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        state.record()
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordClearsHistoryRetranscribeIntentLatchAfterRejectedRecordStart() throws {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        state.record()
        let recordID = try XCTUnwrap(sentCommands.last?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "record",
            "outcome": "reject",
            "id": recordID,
            "reason": "busy",
        ])
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        let historyCommands = sentCommands.filter { $0["cmd"] as? String == "retranscribe_recording" }
        XCTAssertEqual(historyCommands.count, 2)
        XCTAssertEqual(historyCommands.last?["audio_path"] as? String, secondAudioPath)
    }

    func testHistoryEntryRetranscribeDebouncesWhilePending() {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertEqual(sentCommands.first?["audio_path"] as? String, firstAudioPath)
    }

    func testLateHistoryRetranscribeFinalDoesNotPasteIntoNewBarRecording() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
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
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        state.record()
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(pastedTexts, [])
    }

    func testHistoryRetranscribePendingClearsWhenDaemonReturnsIdleWithoutTranscript() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        XCTAssertTrue(state.isHistoryRetranscriptionPending)

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertFalse(state.isHistoryRetranscriptionPending)
    }

    func testHistoryRetranscribeUsesExtendedTranscriptionTimeout() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.transcriptionTimeout = .milliseconds(20)
        state.barInitiatedTranscriptionTimeout = .seconds(30)
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertTrue(state.isHistoryRetranscriptionPending)
        XCTAssertNil(state.errorMessage)
    }

    func testHistoryRetranscribeValidationErrorSurvivesImmediateRecordingIdle() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-missing/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "error",
            "message": "Archived recording audio does not exist",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Archived recording audio does not exist")
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
