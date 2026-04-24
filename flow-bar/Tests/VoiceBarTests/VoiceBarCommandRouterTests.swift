@testable import VoiceBar
import XCTest

final class VoiceBarCommandRouterTests: XCTestCase {
    func testToggleStartsRecordingIntentWhenIdle() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        try VoiceBarCommandRouter.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")), voiceState: state)

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "record")
        XCTAssertNotNil(commands.first?["id"] as? String)
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
        var idleCommands: [[String: Any]] = []
        idleState.sendCommand = { idleCommands.append($0) }
        try VoiceBarCommandRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording")),
            voiceState: idleState
        )
        XCTAssertEqual(idleState.mode, .idle)
        XCTAssertEqual(idleCommands.count, 1)
        XCTAssertEqual(idleCommands.first?["cmd"] as? String, "record")
        XCTAssertNotNil(idleCommands.first?["id"] as? String)

        let transcribingState = VoiceState()
        transcribingState.mode = .transcribing
        var transcribingCommands: [[String: Any]] = []
        transcribingState.sendCommand = { transcribingCommands.append($0) }
        try VoiceBarCommandRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording")),
            voiceState: transcribingState
        )
        XCTAssertEqual(transcribingState.mode, .transcribing)
        XCTAssertTrue(transcribingCommands.isEmpty)
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
