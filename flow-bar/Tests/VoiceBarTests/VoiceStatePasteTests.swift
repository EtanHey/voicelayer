@testable import VoiceBar
import XCTest

final class VoiceStatePasteTests: XCTestCase {
    func testBarInitiatedTranscribingIgnoresStaleIdleUntilTranscriptionArrives() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        XCTAssertEqual(state.mode, .transcribing)
    }

    func testRepasteUsesStoredTranscript() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "test capture from codex",
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["test capture from codex"])
    }

    func testRecentTranscriptionsAreMostRecentFirst() {
        let state = VoiceState()

        state.handleEvent([
            "type": "transcription",
            "text": "first note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "second note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "third note",
        ])

        XCTAssertEqual(state.recentTranscriptions, [
            "third note",
            "second note",
            "first note",
        ])
    }
}
