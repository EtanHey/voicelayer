@testable import VoiceBar
import XCTest

final class SocketServerTests: XCTestCase {
    deinit {}

    func testControlStartRecordingRoutesToControlHandler() {
        let expectation = expectation(description: "control command routed")
        let server = SocketServer(state: VoiceState())
        server.onControlCommand = { command in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(command, .startRecording)
            expectation.fulfill()
        }

        server.parseLine(#"{"type":"control","command":"start-recording"}"#)

        wait(for: [expectation], timeout: 1)
    }

    func testControlUnknownCommandDoesNotRouteToControlHandler() {
        let expectation = expectation(description: "unknown control command ignored")
        expectation.isInverted = true
        let server = SocketServer(state: VoiceState())
        server.onControlCommand = { _ in
            expectation.fulfill()
        }

        server.parseLine(#"{"type":"control","command":"unknown-command"}"#)

        wait(for: [expectation], timeout: 0.2)
    }

    func testStateEventsStillRouteToVoiceState() {
        let state = VoiceState()
        let expectation = expectation(description: "state event routed")
        state.onModeChange = { mode in
            if mode == .recording {
                expectation.fulfill()
            }
        }
        let server = SocketServer(state: state)

        server.parseLine(#"{"type":"state","state":"recording"}"#)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(state.mode, .recording)
    }
}
