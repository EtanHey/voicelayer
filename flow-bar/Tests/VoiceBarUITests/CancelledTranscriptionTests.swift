@testable import VoiceBarUI
import XCTest

final class CancelledTranscriptionTests: XCTestCase {
    private func fixtureState() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.frontmostAppProvider = { nil }
        state.minimumTranscribingDisplayDuration = 0
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
        XCTAssertEqual(commands, ["cancel"])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.confirmationText,
                       "Transcription cancelled — audio saved. Re-transcribe it from History once processing finishes.")
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertTrue(state.latestReusableTranscript.isEmpty)
        XCTAssertNil(state.lastDictationCardEntry)
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertNotNil(state.confirmationText)
        state.record(pressToTalk: true)
        XCTAssertNil(state.confirmationText)
    }

    func testCancelDropsADeferredFinalInsteadOfSavingOrPastingIt() {
        let state = fixtureState()
        state.minimumTranscribingDisplayDuration = 60
        var pasted: [String] = []
        state.pasteHandler = { pasted.append($0)
            return true
        }
        state.pasteboardWriter = { pasted.append($0) }
        state.handleEvent(["type": "transcription", "text": "Synthetic deferred words",
                           "recording_path": "/tmp/synthetic-cancel/audio.wav"])
        state.cancel()
        XCTAssertEqual(state.mode, .idle)
        XCTAssertTrue(state.latestReusableTranscript.isEmpty)
        XCTAssertNil(state.lastDictationCardEntry)
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(state.confirmationText,
                       "Transcription cancelled — audio saved. Re-transcribe it from History once processing finishes.")
    }
}
