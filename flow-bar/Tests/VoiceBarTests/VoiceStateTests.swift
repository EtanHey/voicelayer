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

    func testCancelIntentDoesNotTransitionLocally() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.cancel()

        XCTAssertEqual(state.mode, .recording)
    }

    func testStopWithoutDaemonResponseDoesNotFallbackToIdle() async {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.stop()
        try? await Task.sleep(for: .milliseconds(2200))

        XCTAssertEqual(state.mode, .recording)
    }
}
