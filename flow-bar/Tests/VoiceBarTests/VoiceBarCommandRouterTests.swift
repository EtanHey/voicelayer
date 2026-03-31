@testable import VoiceBar
import XCTest

final class VoiceBarCommandRouterTests: XCTestCase {
    func testToggleStartsRecordingWhenIdle() throws {
        let state = VoiceState()

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")), voiceState: state)

        XCTAssertEqual(state.mode, .recording)
    }

    func testToggleStopsRecordingWhenAlreadyRecording() throws {
        let state = VoiceState()
        state.mode = .recording

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")), voiceState: state)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "stop")
    }

    func testStartRecordingOnlyTriggersFromIdle() throws {
        let idleState = VoiceState()
        try VoiceBarCommandRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording")),
            voiceState: idleState
        )
        XCTAssertEqual(idleState.mode, .recording)

        let transcribingState = VoiceState()
        transcribingState.mode = .transcribing
        try VoiceBarCommandRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording")),
            voiceState: transcribingState
        )
        XCTAssertEqual(transcribingState.mode, .transcribing)
    }

    func testStopRecordingOnlyTriggersFromRecordingMode() throws {
        let state = VoiceState()
        state.mode = .recording

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "voicebar://stop-recording")), voiceState: state)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "stop")

        let idleState = VoiceState()
        idleState.sendCommand = { commands.append($0) }
        try VoiceBarCommandRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://stop-recording")),
            voiceState: idleState
        )
        XCTAssertEqual(commands.count, 1)
    }

    func testIgnoresUnknownOrNonVoiceBarUrls() throws {
        let state = VoiceState()

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "https://example.com")), voiceState: state)
        XCTAssertEqual(state.mode, .idle)

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "voicebar://unknown")), voiceState: state)
        XCTAssertEqual(state.mode, .idle)
    }
}
