import XCTest
@testable import VoiceBarUI

final class CloneEngineSnapshotTests: XCTestCase {
    func testVoiceStateAcceptsLifecycleWithoutChangingRecordingMode() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "recording"])
        let before = state.mode
        let event = CloneEngineSnapshot(state: .restarting, since: "2026-11-05T00:00:00Z",
            reason: "engine_exited", pid: nil, startWithVoiceBar: true)
        state.handleEvent(event.payload)
        XCTAssertEqual(state.cloneEngine, event)
        XCTAssertEqual(state.mode, before)
        var ack: SocketAckEvent?
        state.onAckEvent = { ack = $0 }
        state.handleEvent(["type": "ack", "command": "clone_engine", "outcome": "reject", "reason": "foreign_engine", "id": "engine"])
        XCTAssertEqual(ack?.command, .cloneEngine)
        XCTAssertEqual(ack?.reason, "foreign_engine")
        var invalid = event.payload
        invalid["state"] = "invented"
        state.handleEvent(invalid)
        XCTAssertEqual(state.cloneEngine, event)
        invalid = event.payload; invalid["pid"] = true
        XCTAssertNil(CloneEngineSnapshot(payload: invalid))
        invalid = event.payload; invalid["start_with_voicebar"] = 1
        XCTAssertNil(CloneEngineSnapshot(payload: invalid))
    }
}
