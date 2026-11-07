@testable import VoiceBarUI
import XCTest

final class CancelledTranscriptionTests: XCTestCase {
    private func fixtureState() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.frontmostAppProvider = { nil }
        state.isConnected = true
        state.sendCommand = { _ in }
        state.record(pressToTalk: true)
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.stop()
        return state
    }

    func testCancelAfterStopShowsAudioRecoveryNoticeWithoutTextOrPaste() {
        let state = fixtureState()
        var commands: [String] = []
        var pasted: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as? String ?? "") }
        state.pasteHandler = { pasted.append($0)
            return true
        }
        state.pasteboardWriter = { pasted.append($0) }
        state.cancel()
        XCTAssertFalse(state.isRecordingDrainPending)
        XCTAssertEqual(commands, ["cancel"])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.confirmationText,
                       "Transcription cancelled. Audio saved. Re-transcribe it from History when processing finishes.")
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertTrue(state.latestReusableTranscript.isEmpty)
        XCTAssertNil(state.lastDictationCardEntry)
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertNotNil(state.confirmationText)
        state.record(pressToTalk: true)
        XCTAssertEqual(commands, ["cancel", "record"])
        XCTAssertNil(state.confirmationText)
    }

    func testOwnedCancelAfterStopKeepsDrainUntilBackendSnapshotThenAllowsRecording() {
        let state = fixtureState()
        let snapshot: ([[String: String]], String?) -> Void = { jobs, mic in
            state.handleEvent(["type": "state", "state": mic == nil ? "transcribing" : "recording",
                               "recording_jobs": jobs, "mic_take_id": mic as Any])
        }
        let processing = ["take_id": "A", "kind": "live", "phase": "processing"]
        snapshot([processing, ["take_id": "B", "kind": "live", "phase": "draining"]], "B")
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.cancel()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "cancel")
        XCTAssertEqual(commands.first?["take_id"] as? String, "B")
        XCTAssertTrue(state.isRecordingDrainPending)
        XCTAssertEqual(state.microphoneTakeID, "B")
        XCTAssertEqual(state.processingTakeCount, 1)
        snapshot([processing], nil)
        XCTAssertFalse(state.isRecordingDrainPending)
        XCTAssertNil(state.microphoneTakeID)
        state.record(pressToTalk: true)
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["cancel", "record"])
        XCTAssertNil(state.confirmationText)
    }

    func testCancelAfterFinalCannotEraseAlreadyDispatchedWords() {
        let state = fixtureState()
        var pasted: [String] = []
        state.pasteHandler = { pasted.append($0); return true }
        state.handleEvent(["type": "transcription", "text": "Synthetic final words",
                           "recording_path": "/tmp/synthetic-cancel/audio.wav"])
        XCTAssertEqual(pasted, ["Synthetic final words"])
        state.cancel()
        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Synthetic final words")
        XCTAssertEqual(pasted, ["Synthetic final words"])
    }
}
