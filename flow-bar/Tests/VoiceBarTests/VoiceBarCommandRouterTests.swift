@testable import VoiceBar
import XCTest

final class VoiceBarCommandRouterTests: XCTestCase {
    final class SpyCommandRouter: VoiceBarCommandRouter {
        var handledURLs: [URL] = []
        var holdStartCount = 0
        var doubleTapCount = 0

        init() {
            super.init(voiceState: VoiceState())
        }

        override func handle(url: URL) {
            handledURLs.append(url)
        }

        override func handleHotkeyHoldStart() {
            holdStartCount += 1
        }

        override func handleHotkeyDoubleTap() {
            doubleTapCount += 1
        }
    }

    func testToggleStartsRecordingIntentWhenIdle() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        let router = VoiceBarCommandRouter(voiceState: state)
        state.sendCommand = { commands.append($0) }

        try router.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")))

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "record")
        XCTAssertEqual(commands.first?["press_to_talk"] as? Bool, true)
        XCTAssertNotNil(commands.first?["id"] as? String)
    }

    func testToggleStopsRecordingWhenAlreadyRecording() throws {
        let state = VoiceState()
        state.mode = .recording
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        try router.handle(url: XCTUnwrap(URL(string: "voicebar://toggle")))

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "stop")
    }

    func testStartRecordingOnlyTriggersFromIdle() throws {
        let idleState = VoiceState()
        let idleRouter = VoiceBarCommandRouter(voiceState: idleState)
        var idleCommands: [[String: Any]] = []
        idleState.sendCommand = { idleCommands.append($0) }
        try idleRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording"))
        )
        XCTAssertEqual(idleState.mode, .idle)
        XCTAssertEqual(idleCommands.count, 1)
        XCTAssertEqual(idleCommands.first?["cmd"] as? String, "record")
        XCTAssertEqual(idleCommands.first?["press_to_talk"] as? Bool, true)
        XCTAssertNotNil(idleCommands.first?["id"] as? String)

        let transcribingState = VoiceState()
        transcribingState.mode = .transcribing
        let transcribingRouter = VoiceBarCommandRouter(voiceState: transcribingState)
        var transcribingCommands: [[String: Any]] = []
        transcribingState.sendCommand = { transcribingCommands.append($0) }
        try transcribingRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://start-recording"))
        )
        XCTAssertEqual(transcribingState.mode, .transcribing)
        XCTAssertTrue(transcribingCommands.isEmpty)
    }

    func testStopRecordingOnlyTriggersFromRecordingMode() throws {
        let state = VoiceState()
        state.mode = .recording
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        try router.handle(url: XCTUnwrap(URL(string: "voicebar://stop-recording")))

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "stop")

        let idleState = VoiceState()
        let idleRouter = VoiceBarCommandRouter(voiceState: idleState)
        idleState.sendCommand = { commands.append($0) }
        try idleRouter.handle(
            url: XCTUnwrap(URL(string: "voicebar://stop-recording"))
        )
        XCTAssertEqual(commands.count, 1)
    }

    func testHotkeyHoldStartUsesPressToTalkRecording() {
        let state = VoiceState()
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        router.handleHotkeyHoldStart()

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "record")
        XCTAssertEqual(commands.first?["press_to_talk"] as? Bool, true)
    }

    func testHotkeyHoldStartIgnoresNonIdleStates() {
        let state = VoiceState()
        state.mode = .recording
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        router.handleHotkeyHoldStart()

        XCTAssertTrue(commands.isEmpty)
    }

    func testPrimaryTapUsesPressToTalkRecording() {
        let state = VoiceState()
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        router.handlePrimaryTap()

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "record")
        XCTAssertEqual(commands.first?["press_to_talk"] as? Bool, true)
    }

    func testHotkeyHoldEndStopsRecordingAfterShortHold() {
        let state = VoiceState()
        state.mode = .recording
        let router = VoiceBarCommandRouter(voiceState: state)

        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        router.handleHotkeyHoldEnd(holdDuration: 0.35)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "stop")
    }

    func testIgnoresUnknownOrNonVoiceBarUrls() throws {
        let state = VoiceState()
        let router = VoiceBarCommandRouter(voiceState: state)

        try router.handle(url: XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertEqual(state.mode, .idle)

        try router.handle(url: XCTUnwrap(URL(string: "voicebar://unknown")))
        XCTAssertEqual(state.mode, .idle)
    }

    func testAppDelegateRoutesURLThroughInjectedRouterWithoutDirectStateMutation() throws {
        let app = AppDelegate()
        let spyRouter = SpyCommandRouter()
        app.commandRouter = spyRouter

        try app.application(NSApplication.shared, open: [
            XCTUnwrap(URL(string: "voicebar://toggle")),
        ])

        XCTAssertEqual(spyRouter.handledURLs.map(\.absoluteString), ["voicebar://toggle"])
        XCTAssertEqual(app.voiceState.mode, .idle)
    }

    func testAppDelegateRoutesHotkeyCallbacksThroughInjectedRouterWithoutDirectStateMutation() {
        let app = AppDelegate()
        let spyRouter = SpyCommandRouter()
        app.commandRouter = spyRouter

        app.handleHotkeyHoldStart()
        app.handleHotkeyDoubleTap()

        XCTAssertEqual(spyRouter.holdStartCount, 1)
        XCTAssertEqual(spyRouter.doubleTapCount, 1)
        XCTAssertEqual(app.voiceState.mode, .idle)
    }
}
