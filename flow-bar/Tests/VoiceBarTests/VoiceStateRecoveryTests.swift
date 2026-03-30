@testable import VoiceBar
import XCTest

final class VoiceStateRecoveryTests: XCTestCase {
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

    func testTranscribingTimesOutAfterThirtySeconds() async {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Transcription failed")
    }

    func testConnectionDropShowsDisconnectedState() {
        let state = VoiceState()
        state.setConnectionStatus(true)

        state.setConnectionStatus(false)

        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.mode, .disconnected)
    }
}
