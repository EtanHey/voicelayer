import AppKit
@testable import VoiceBarUI
import XCTest

final class CancelledTranscriptionTests: XCTestCase {
    func testCancelAfterStopKeepsDecodeVisibleAndSavesWithoutPasting() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        var pasteAttempts = 0
        state.frontmostAppProvider = { nil }
        state.pasteHandler = { _ in pasteAttempts += 1
            return true
        }
        var writes: [String] = []
        state.pasteboardWriter = { text in writes.append(text) }
        state.minimumTranscribingDisplayDuration = 0
        state.isConnected = true
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as? String ?? "") }
        state.record(pressToTalk: true)
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.stop()
        state.cancel()
        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(commands.last, "cancel")
        state.handleEvent(["type": "transcription", "text": "Synthetic preserved words.",
                           "recording_path": "/tmp/synthetic-cancel/audio.wav"])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertEqual(state.latestReusableTranscript, "Synthetic preserved words.")
        XCTAssertEqual(state.lastDictationCardEntry?.text, "Synthetic preserved words.")
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.confirmationText, "Transcription cancelled — not pasted")
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(pasteAttempts, 0)
        XCTAssertTrue(writes.isEmpty, "cancel must never auto-paste")
        state.copyTranscript(state.latestReusableTranscript)
        XCTAssertEqual(writes, ["Synthetic preserved words."])
    }

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

    func testWireSuppressionPreventsPasteWithoutALocalCancel() {
        let state = fixtureState()
        var pasted: [String] = []
        state.pasteHandler = { pasted.append($0)
            return true
        }
        state.handleEvent(["type": "transcription", "text": "Wire retained words",
                           "recording_path": "/tmp/synthetic-wire/audio.wav", "paste_suppressed": true])
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(state.latestReusableTranscript, "Wire retained words")
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.confirmationText, "Transcription cancelled — not pasted")
    }

    func testTerminalCleanupAllowsAnExplicitRecoveryToPaste() {
        let endings: [(VoiceState) -> Void] = [
            { $0.handleEvent(["type": "transcription", "text": ""]) },
            { $0.dismissError() },
            { $0.setConnectionStatus(false)
                $0.setConnectionStatus(true) },
        ]
        for end in endings {
            let state = fixtureState()
            var pasted: [String] = []
            state.pasteHandler = { pasted.append($0)
                return true
            }
            state.cancel()
            end(state)
            state.retranscribeLastCapture()
            state.handleEvent(["type": "state", "state": "transcribing"])
            state.handleEvent(["type": "transcription", "text": "Explicit recovery words"])
            XCTAssertEqual(pasted, ["Explicit recovery words"])
        }
    }
}
