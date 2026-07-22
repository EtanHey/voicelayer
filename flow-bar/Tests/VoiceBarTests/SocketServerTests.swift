import AppKit
import Darwin
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class SocketServerTests: XCTestCase {
    private var windows: [NSWindow] = []
    deinit {}

    func testUnstartedServerDeinitDoesNotUnlinkSocketPathItDoesNotOwn() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("voicelayer.sock")
        FileManager.default.createFile(atPath: socketURL.path, contents: Data("owned by another server".utf8))

        weak var releasedServer: SocketServer?
        do {
            let server = SocketServer(state: VoiceState(), socketPath: socketURL.path)
            releasedServer = server
        }

        XCTAssertNil(releasedServer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
    }

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

    func testQAContextMenuProbeRoutesOnlyWhenExplicitlyInstalled() {
        let expectation = expectation(description: "QA context-menu probe routed")
        let server = SocketServer(state: VoiceState())
        server.onQAContextMenuProbe = {
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }

        server.parseLine(#"{"type":"qa_context_menu_probe"}"#)

        wait(for: [expectation], timeout: 1)
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

    func testBrokenMicCaptureFailureRoutesToDaemonControllerCallbackAndVoiceState() {
        let state = VoiceState()
        let expectation = expectation(description: "capture failure routed")
        let server = SocketServer(state: state)
        server.onCaptureFailure = { failureType in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(failureType, "broken-mic")
            expectation.fulfill()
        }

        server.parseLine(
            #"{"type":"error","message":"Microphone returned silence","recoverable":true,"show_during_bar_recording":true,"capture_failure":"broken-mic"}"#
        )

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Microphone returned silence")
    }

    func testCommandsAreSentOnlyToClientHelloCommandOwner() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("voicelayer.sock")
        let server = SocketServer(state: VoiceState(), socketPath: socketURL.path)
        server.start()
        defer { server.stop() }

        XCTAssertTrue(waitForSocket(at: socketURL.path))

        let passiveClient = try connectUnixSocket(path: socketURL.path)
        let commandClient = try connectUnixSocket(path: socketURL.path)
        defer {
            close(passiveClient)
            close(commandClient)
        }

        try writeLine(
            #"{"type":"client_hello","role":"mcp-server","pid":111,"accepts_commands":false}"#,
            to: passiveClient
        )
        try writeLine(
            #"{"type":"client_hello","role":"mcp-daemon","pid":222,"accepts_commands":true}"#,
            to: commandClient
        )

        Thread.sleep(forTimeInterval: 0.1)
        server.sendCommandToOwner(command: ["cmd": "record"])

        let commandLine = try readLine(from: commandClient, timeout: 1)
        XCTAssertNotNil(commandLine)
        XCTAssertTrue(commandLine?.contains(#""cmd":"record""#) == true || commandLine?.contains(#""record""#) == true)
        XCTAssertNil(try readLine(from: passiveClient, timeout: 0.2))
    }

    func testStopInterruptReachesLegacyPlaybackClientAndCommandOwner() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }

        fixture.server.sendCommandToOwner(command: ["cmd": "stop"])

        XCTAssertTrue(try XCTUnwrap(readLine(from: fixture.legacyClient, timeout: 1)).contains(#""cmd":"stop""#))
        XCTAssertTrue(try XCTUnwrap(readLine(from: fixture.commandClient, timeout: 1)).contains(#""cmd":"stop""#))
    }

    func testStopInterruptReachesEveryPlaybackClientWhenLatestSpeakingOwnerOverlapsAnEarlierOwner() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("voicelayer.sock")
        let state = VoiceState()
        let server = SocketServer(state: state, socketPath: socketURL.path)
        server.start()
        defer { server.stop() }
        XCTAssertTrue(waitForSocket(at: socketURL.path))

        let earlierPlaybackClient = try connectUnixSocket(path: socketURL.path)
        let latestPlaybackClient = try connectUnixSocket(path: socketURL.path)
        let commandClient = try connectUnixSocket(path: socketURL.path)
        defer {
            close(earlierPlaybackClient)
            close(latestPlaybackClient)
            close(commandClient)
        }

        try writeLine(
            #"{"type":"client_hello","role":"mcp-server","pid":111,"accepts_commands":false}"#,
            to: earlierPlaybackClient
        )
        try writeLine(
            #"{"type":"client_hello","role":"mcp-server","pid":222,"accepts_commands":false}"#,
            to: latestPlaybackClient
        )
        try writeLine(
            #"{"type":"client_hello","role":"mcp-daemon","pid":333,"accepts_commands":true}"#,
            to: commandClient
        )
        try writeLine(
            #"{"type":"state","state":"speaking","text":"Earlier overlapping playback"}"#,
            to: earlierPlaybackClient
        )
        try writeLine(
            #"{"type":"state","state":"speaking","text":"Latest visible playback"}"#,
            to: latestPlaybackClient
        )
        XCTAssertTrue(waitForMode(state, mode: .speaking, timeout: 1))

        server.sendCommandToOwner(command: ["cmd": "stop"])

        XCTAssertTrue(
            try XCTUnwrap(readLine(from: earlierPlaybackClient, timeout: 1)).contains(#""cmd":"stop""#)
        )
        XCTAssertTrue(
            try XCTUnwrap(readLine(from: latestPlaybackClient, timeout: 1)).contains(#""cmd":"stop""#)
        )
        XCTAssertTrue(try XCTUnwrap(readLine(from: commandClient, timeout: 1)).contains(#""cmd":"stop""#))
    }

    @MainActor
    func testReplayAfterFinishedPlaybackRoutesToTheClientThatOwnedTheLastSpeak() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }

        try writeLine(
            #"{"type":"state","state":"speaking","text":"Replay survives playback idle"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))
        try writeLine(
            #"{"type":"state","state":"idle","source":"playback"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .idle, timeout: 1))

        fixture.server.sendCommandToOwner(command: ["cmd": "replay", "id": "finished-replay"])

        let replay = try XCTUnwrap(readLine(from: fixture.legacyClient, timeout: 1))
        XCTAssertTrue(replay.contains(#""cmd":"replay""#))
        XCTAssertTrue(replay.contains(#""id":"finished-replay""#))
        XCTAssertNil(try readLine(from: fixture.commandClient, timeout: 0.2))
    }

    @MainActor
    func testReplayDuringVoiceAskRoutesOnlyToTheActivePlaybackOwner() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }

        try writeLine(
            #"{"type":"state","state":"speaking","text":"Question playback remains blocking"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))

        fixture.server.sendCommandToOwner(command: ["cmd": "replay", "id": "active-replay"])

        let replay = try XCTUnwrap(readLine(from: fixture.legacyClient, timeout: 1))
        XCTAssertTrue(replay.contains(#""cmd":"replay""#))
        XCTAssertNil(try readLine(from: fixture.commandClient, timeout: 0.2))
    }

    @MainActor
    func testRealSpeakingStopButtonInterruptsPlaybackOwnerThroughSocketThenReachesIdle() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }
        fixture.state.sendCommand = { fixture.server.sendCommandToOwner(command: $0) }

        try writeLine(
            #"{"type":"state","state":"speaking","text":"Etan runs supabase cmuxlayer golems and BrainLayer"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))

        let router = VoiceBarCommandRouter(voiceState: fixture.state)
        let host = NSHostingView(rootView: BarView(state: fixture.state, commandRouter: router))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        presentOffscreenForInteraction(window)
        windows.append(window)
        host.layoutSubtreeIfNeeded()

        let legacyStop = try clickSpeakingStop(
            host,
            in: window,
            playbackClient: fixture.legacyClient
        )

        XCTAssertTrue(legacyStop.contains(#""cmd":"stop""#))
        let stopPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(legacyStop.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(stopPayload["playback_elapsed_ms"] as? Int)
        XCTAssertTrue(
            try XCTUnwrap(readLine(from: fixture.commandClient, timeout: 1)).contains(#""cmd":"stop""#)
        )
        try writeLine(#"{"type":"state","state":"idle","source":"playback"}"#, to: fixture.legacyClient)
        XCTAssertTrue(waitForMode(fixture.state, mode: .idle, timeout: 1))
    }

    @MainActor
    func testRealSpeakingReplayButtonRoutesAtomicReplayToPlaybackOwner() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }
        fixture.state.sendCommand = { fixture.server.sendCommandToOwner(command: $0) }

        try writeLine(
            #"{"type":"state","state":"speaking","text":"Replay the active teleprompter output"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))

        let router = VoiceBarCommandRouter(voiceState: fixture.state)
        let host = NSHostingView(rootView: BarView(state: fixture.state, commandRouter: router))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        presentOffscreenForInteraction(window)
        windows.append(window)
        host.layoutSubtreeIfNeeded()

        try click(
            host,
            at: NSPoint(x: host.bounds.midX - 28, y: 23),
            in: window
        )

        let replayCommand = try XCTUnwrap(readLine(from: fixture.legacyClient, timeout: 1))
        XCTAssertTrue(replayCommand.contains(#""cmd":"replay""#))
        XCTAssertTrue(replayCommand.contains(#""id":"#))
        XCTAssertNil(try readLine(from: fixture.commandClient, timeout: 0.2))
    }

    @MainActor
    func testRapidActiveReplayForwardsOnlyReplayIntentsToPlaybackOwner() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }
        fixture.state.sendCommand = { fixture.server.sendCommandToOwner(command: $0) }
        try writeLine(
            #"{"type":"state","state":"speaking","text":"Rapid replay must not echo"}"#,
            to: fixture.legacyClient
        )
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))

        let router = VoiceBarCommandRouter(voiceState: fixture.state)
        router.handleReplay()
        router.handleReplay()

        let replays = try readLines(from: fixture.legacyClient, count: 3, timeout: 0.2)
        XCTAssertEqual(replays.count, 2)
        XCTAssertTrue(replays.allSatisfy { $0.contains(#""cmd":"replay""#) })
        XCTAssertTrue(replays.allSatisfy { !$0.contains(#""cmd":"stop""#) })
        XCTAssertNil(try readLine(from: fixture.commandClient, timeout: 0.2))
    }

    @MainActor
    func testF18AndEscapeEventsDriveProductionDispatcherToPlaybackStopAndIdle() throws {
        let fixture = try makeConnectedServerFixture()
        defer { fixture.cleanup() }
        fixture.state.sendCommand = { fixture.server.sendCommandToOwner(command: $0) }
        let router = VoiceBarCommandRouter(voiceState: fixture.state)
        var f18DownCount = 0

        let f18 = hotkeyAction(
            type: .keyDown,
            keycode: 79,
            flags: [],
            autorepeat: 0,
            targetKeycodes: HotkeyManager.defaultTargetKeycodes,
            useModifierMode: false
        )
        dispatchHotkeyAction(f18, onKeyDown: { f18DownCount += 1 }, onCancel: { router.handleEscape() })
        XCTAssertTrue(waitForCondition(timeout: 1) { f18DownCount == 1 })

        try writeLine(#"{"type":"state","state":"speaking","text":"Etan"}"#, to: fixture.legacyClient)
        XCTAssertTrue(waitForMode(fixture.state, mode: .speaking, timeout: 1))
        let escape = hotkeyAction(
            type: .keyDown,
            keycode: 53,
            flags: [],
            autorepeat: 0,
            targetKeycodes: HotkeyManager.defaultTargetKeycodes,
            useModifierMode: false,
            cancellationIsActive: router.shouldHandleEscape
        )
        dispatchHotkeyAction(escape, onKeyDown: {}, onCancel: { router.handleEscape() })
        XCTAssertTrue(waitForCondition(timeout: 1) {
            fixture.state.mode == .speaking
        })
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertTrue(try XCTUnwrap(readLine(from: fixture.legacyClient, timeout: 1)).contains(#""cmd":"stop""#))
        XCTAssertTrue(
            try XCTUnwrap(readLine(from: fixture.commandClient, timeout: 1)).contains(#""cmd":"stop""#)
        )
        try writeLine(#"{"type":"state","state":"idle","source":"playback"}"#, to: fixture.legacyClient)
        XCTAssertTrue(waitForMode(fixture.state, mode: .idle, timeout: 1))
    }

    func testPassiveClientDoesNotMarkVoiceBarConnectedUntilCommandOwnerRegisters() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("voicelayer.sock")
        let state = VoiceState()
        let server = SocketServer(state: state, socketPath: socketURL.path)
        server.start()
        defer { server.stop() }

        XCTAssertTrue(waitForSocket(at: socketURL.path))

        let passiveClient = try connectUnixSocket(path: socketURL.path)
        let commandClient = try connectUnixSocket(path: socketURL.path)
        defer {
            close(passiveClient)
            close(commandClient)
        }

        try writeLine(
            #"{"type":"client_hello","role":"mcp-server","pid":111,"accepts_commands":false}"#,
            to: passiveClient
        )
        XCTAssertFalse(waitForConnectionStatus(state, connected: true, timeout: 0.2))
        XCTAssertFalse(state.isConnected)

        try writeLine(
            #"{"type":"client_hello","role":"mcp-daemon","pid":222,"accepts_commands":true}"#,
            to: commandClient
        )
        XCTAssertTrue(waitForConnectionStatus(state, connected: true, timeout: 1))
    }

    func testNoCommandOwnerRejectsPendingRecordIntent() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("voicelayer.sock")
        let state = VoiceState()
        let server = SocketServer(state: state, socketPath: socketURL.path)
        state.sendCommand = { command in
            server.sendCommandToOwner(command: command)
        }
        server.start()
        defer { server.stop() }

        XCTAssertTrue(waitForSocket(at: socketURL.path))

        state.record(pressToTalk: true)

        XCTAssertTrue(waitForMode(state, mode: .error, timeout: 1))
        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.hotkeyPhase, .idle)
        XCTAssertEqual(state.errorMessage, "VoiceLayer is starting")
    }
}

/// Runtime-only leg. The Bun corpus harness owns the daemon lifecycle, then
/// releases its temporary VoiceBar server so this test can bind the exact same
/// isolated socket and exercise production input/UI event dispatch against the
/// still-running daemon.
final class CorpusReplayRuntimeInteractionTests: XCTestCase {
    private final class ScratchCmuxApplication: NSRunningApplication, @unchecked Sendable {
        override var bundleIdentifier: String? {
            "com.cmuxterm.app"
        }

        override var processIdentifier: pid_t {
            52005
        }
    }

    private func writeTerminalProof(
        environmentKey: String,
        environment: [String: String],
        workDirectory: String
    ) throws {
        guard let rawProofPath = environment[environmentKey],
              !rawProofPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            XCTFail("missing \(environmentKey) runtime proof path")
            return
        }
        let workDirectoryURL = URL(fileURLWithPath: workDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let proofURL = URL(fileURLWithPath: rawProofPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard proofURL.deletingLastPathComponent().path == workDirectoryURL.path else {
            XCTFail("runtime terminal proof path is outside the verifier work directory")
            return
        }

        try Data("pass\n".utf8).write(to: proofURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: proofURL.path
        )
    }

    @MainActor
    func testF18EscapeAndStopButtonDriveSpawnedDaemonNDJSON() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawSocketPath = environment["VOICELAYER_VERIFY_VOICEBAR_SOCKET_PATH"],
              !rawSocketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawMCPSocketPath = environment["VOICELAYER_VERIFY_MCP_SOCKET_PATH"],
              !rawMCPSocketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawDaemonPID = environment["VOICELAYER_VERIFY_DAEMON_PID"],
              let daemonPID = Int32(rawDaemonPID),
              daemonPID > 0,
              let rawWorkDirectory = environment["VOICELAYER_VERIFY_WORK_DIR"],
              !rawWorkDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let audioFixture = environment["VOICELAYER_VERIFY_AUDIO_FIXTURE"],
              FileManager.default.fileExists(atPath: audioFixture)
        else {
            throw XCTSkip("corpus runtime interaction environment is not configured")
        }

        let socketPath = URL(fileURLWithPath: rawSocketPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let workDirectory = URL(fileURLWithPath: rawWorkDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let expectedSocketPath = URL(fileURLWithPath: workDirectory, isDirectory: true)
            .appendingPathComponent("voicebar.sock")
            .path
        let mcpSocketPath = URL(fileURLWithPath: rawMCPSocketPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let expectedMCPSocketPath = URL(fileURLWithPath: workDirectory, isDirectory: true)
            .appendingPathComponent("mcp.sock")
            .path
        guard socketPath == expectedSocketPath, mcpSocketPath == expectedMCPSocketPath else {
            XCTFail("runtime sockets are outside the verifier work directory")
            return
        }

        let state = VoiceState()
        state.minimumTranscribingDisplayDuration = 0
        state.barInitiatedTranscriptionTimeout = .seconds(240)
        let server = SocketServer(state: state, socketPath: rawSocketPath)
        var replayIntentCount = 0
        state.sendCommand = { command in
            if command["cmd"] as? String == "replay" {
                replayIntentCount += 1
            }
            server.sendCommandToOwner(command: command)
        }
        server.start()
        defer {
            state.sendCommand = nil
            state.onModeChange = nil
            server.stop()
        }

        guard waitForSocket(at: rawSocketPath, timeout: 10) else {
            XCTFail("runtime VoiceBar socket was not created")
            return
        }
        let reconnectTimeout = Double(
            environment["VOICELAYER_VERIFY_DAEMON_RECONNECT_TIMEOUT"] ?? "30"
        ) ?? 30
        guard waitForConnectionStatus(state, connected: true, timeout: reconnectTimeout) else {
            XCTFail("spawned daemon did not reconnect to the runtime VoiceBar socket")
            return
        }

        let router = VoiceBarCommandRouter(voiceState: state)
        var recordingTransitions = 0
        var idleTransitions = 0
        state.onModeChange = { mode in
            if mode == .recording { recordingTransitions += 1 }
            if mode == .idle { idleTransitions += 1 }
        }

        dispatchRuntimeKey(virtualKey: 79, router: router)
        XCTAssertTrue(waitForCondition(timeout: 15) { recordingTransitions >= 2 })

        dispatchRuntimeKey(virtualKey: 53, router: router)
        XCTAssertTrue(waitForCondition(timeout: 15) { idleTransitions >= 2 })

        let cmux = ScratchCmuxApplication()
        var scratchTerminal = ""
        var axInsertionFired = false
        state.frontmostAppProvider = { cmux }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, block in block() }
        state.pasteConfirmationDelay = 0
        state.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                axInsertionFired = true
                let strategy = CommandModeAXHelper.insertionStrategy(
                    text: text,
                    focusedValueLength: (scratchTerminal as NSString).length,
                    targetBundleIdentifier: cmux.bundleIdentifier
                )
                if strategy == .valueRewrite {
                    scratchTerminal.append(text)
                }
                completion()
                return true
            }
        }
        recordingTransitions = 0
        dispatchRuntimeKey(virtualKey: 79, router: router)
        XCTAssertTrue(waitForCondition(timeout: 15) { recordingTransitions >= 2 })

        let host = NSHostingView(rootView: BarView(state: state, commandRouter: router))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        presentOffscreenForInteraction(window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        try clickRecordingStop(host, in: window, state: state)
        // This is the STT half of the mission's paste/subtitle surface: subtitle
        // word boundaries are emitted by the separate TTS playback queue.
        XCTAssertTrue(waitForCondition(timeout: 240) { !state.transcript.isEmpty })
        XCTAssertTrue(axInsertionFired)
        XCTAssertEqual(scratchTerminal, state.transcript)
        XCTAssertEqual(state.lastTranscriptionPolished, true)
        XCTAssertTrue(waitForMode(state, mode: .idle, timeout: 15))
        try writeTerminalProof(
            environmentKey: "VOICELAYER_VERIFY_F5_TERMINAL_PROOF_PATH",
            environment: environment,
            workDirectory: workDirectory
        )

        let veryLongState = VoiceState()
        let veryLongTranscript = String(
            repeating: "A very long dictated terminal transcript must land atomically. ",
            count: 220
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var veryLongScratchTerminal = ""
        var veryLongInsertionAttempts = 0
        veryLongState.sendCommand = { _ in }
        veryLongState.minimumTranscribingDisplayDuration = 0
        veryLongState.pasteConfirmationDelay = 0
        veryLongState.frontmostAppProvider = { cmux }
        veryLongState.targetAppActivator = { _ in }
        veryLongState.pasteScheduler = { _, block in block() }
        veryLongState.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                veryLongInsertionAttempts += 1
                let strategy = CommandModeAXHelper.insertionStrategy(
                    text: text,
                    focusedValueLength: (veryLongScratchTerminal as NSString).length,
                    targetBundleIdentifier: cmux.bundleIdentifier
                )
                if strategy == .valueRewrite {
                    veryLongScratchTerminal.append(text)
                }
                completion()
                return true
            }
        }

        XCTAssertGreaterThan((veryLongTranscript as NSString).length, 10000)
        veryLongState.record()
        veryLongState.handleEvent(["type": "state", "state": "transcribing"])
        veryLongState.handleEvent(["type": "transcription", "text": veryLongTranscript])

        XCTAssertEqual(veryLongInsertionAttempts, 1)
        XCTAssertEqual(veryLongScratchTerminal, veryLongTranscript)
        XCTAssertEqual(veryLongState.confirmationText, veryLongTranscript)
        try writeTerminalProof(
            environmentKey: "VOICELAYER_VERIFY_F5_TERMINAL_VERY_LONG_PROOF_PATH",
            environment: environment,
            workDirectory: workDirectory
        )

        let finishedReplayPhrase = "Finished speech replay must start this exact audio again from the beginning."
        let finishedSpeakStartEpoch = state.playbackEpoch
        let finishedSpeakClient = try sendMCPToolCall(
            socketPath: mcpSocketPath,
            id: "runtime-finished-speak",
            name: "voice_speak",
            arguments: [
                "message": finishedReplayPhrase,
                "mode": "announce",
                "rate": "-10%",
            ]
        )
        defer { close(finishedSpeakClient) }
        XCTAssertTrue(waitForCondition(timeout: 60) {
            state.playbackEpoch > finishedSpeakStartEpoch && state.mode == .speaking
        })
        XCTAssertEqual(state.teleprompterText, finishedReplayPhrase)
        XCTAssertTrue(waitForCondition(timeout: 10) {
            directChildProcessCount(named: "afplay", parentPID: daemonPID) == 1
        })
        XCTAssertTrue(waitForMode(state, mode: .idle, timeout: 60))

        host.frame.size = host.fittingSize
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        let finishedReplayStartEpoch = state.playbackEpoch
        let finishedReplayIntentCount = replayIntentCount
        try click(
            host,
            at: NSPoint(x: host.bounds.midX - 28, y: 23),
            in: window
        )
        XCTAssertTrue(waitForCondition(timeout: 1) {
            replayIntentCount == finishedReplayIntentCount + 1
        })
        XCTAssertTrue(waitForCondition(timeout: 15) {
            state.playbackEpoch > finishedReplayStartEpoch && state.mode == .speaking
        })
        XCTAssertEqual(state.teleprompterText, finishedReplayPhrase)
        XCTAssertTrue(waitForCondition(timeout: 10) {
            directChildProcessCount(named: "afplay", parentPID: daemonPID) == 1
        })
        XCTAssertTrue(waitForMode(state, mode: .idle, timeout: 60))
        print("[replay-runtime] finished replay click fired a fresh afplay process")

        let askReplayPhrase = "Replay this blocking voice ask prompt without entering recording early."
        let askStartEpoch = state.playbackEpoch
        let askClient = try sendMCPToolCall(
            socketPath: mcpSocketPath,
            id: "runtime-active-ask",
            name: "voice_ask",
            arguments: [
                "message": askReplayPhrase,
                "timeout_seconds": 30,
                "silence_mode": "quick",
                "press_to_talk": true,
            ]
        )
        defer { close(askClient) }
        XCTAssertTrue(waitForCondition(timeout: 60) {
            state.playbackEpoch > askStartEpoch && state.mode == .speaking
        })
        XCTAssertEqual(state.teleprompterText, askReplayPhrase)
        XCTAssertTrue(waitForCondition(timeout: 10) {
            directChildProcessCount(named: "afplay", parentPID: daemonPID) == 1
        })
        let originalAskEpoch = state.playbackEpoch

        let askHost = NSHostingView(rootView: BarView(state: state, commandRouter: router))
        askHost.frame = NSRect(origin: .zero, size: askHost.fittingSize)
        let askWindow = NSWindow(
            contentRect: askHost.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        askWindow.contentView = askHost
        presentOffscreenForInteraction(askWindow)
        defer {
            askWindow.orderOut(nil)
            askWindow.contentView = nil
            askWindow.close()
        }
        askHost.layoutSubtreeIfNeeded()
        let askReplayIntentCount = replayIntentCount
        try click(askHost, at: NSPoint(x: askHost.bounds.midX - 28, y: 23), in: askWindow)
        try click(askHost, at: NSPoint(x: askHost.bounds.midX - 28, y: 23), in: askWindow)
        XCTAssertTrue(waitForCondition(timeout: 1) {
            replayIntentCount == askReplayIntentCount + 2
        })

        var maxConcurrentAfplay = directChildProcessCount(named: "afplay", parentPID: daemonPID)
        var sawRestartedAsk = false
        var enteredRecordingBeforeReplay = false
        let restartDeadline = Date().addingTimeInterval(20)
        while Date() < restartDeadline {
            let concurrent = directChildProcessCount(named: "afplay", parentPID: daemonPID)
            maxConcurrentAfplay = max(maxConcurrentAfplay, concurrent)
            XCTAssertLessThanOrEqual(concurrent, 1)
            if state.playbackEpoch > originalAskEpoch {
                sawRestartedAsk = true
                break
            }
            if state.mode == .recording {
                enteredRecordingBeforeReplay = true
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if enteredRecordingBeforeReplay || !sawRestartedAsk {
            router.handleCancel()
            _ = waitForMode(state, mode: .idle, timeout: 15)
            XCTFail(
                enteredRecordingBeforeReplay
                    ? "voice_ask advanced before replay started"
                    : "voice_ask never emitted the restarted speaking epoch"
            )
            return
        }
        XCTAssertEqual(state.teleprompterText, askReplayPhrase)

        let recordingDeadline = Date().addingTimeInterval(60)
        while Date() < recordingDeadline, state.mode != .recording {
            let concurrent = directChildProcessCount(named: "afplay", parentPID: daemonPID)
            maxConcurrentAfplay = max(maxConcurrentAfplay, concurrent)
            XCTAssertLessThanOrEqual(concurrent, 1)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(maxConcurrentAfplay, 1)
        router.handleCancel()
        XCTAssertTrue(waitForMode(state, mode: .idle, timeout: 15))
        print("[replay-runtime] active voice_ask replay stayed blocking; maxConcurrentAfplay=1")
    }
}

private func sendMCPToolCall(
    socketPath: String,
    id: String,
    name: String,
    arguments: [String: Any]
) throws -> Int32 {
    let fd = try connectUnixSocket(path: socketPath, timeout: 10)
    do {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ])
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try writeData(frame, to: fd)
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func writeData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written == -1, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private func directChildProcessCount(named name: String, parentPID: Int32) -> Int {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-P", String(parentPID), "-x", name]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return 0
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return 0 }
    return text.split(whereSeparator: \Character.isNewline).count
}

private struct ConnectedServerFixture {
    let directory: URL
    let state: VoiceState
    let server: SocketServer
    let legacyClient: Int32
    let commandClient: Int32

    func cleanup() {
        state.sendCommand = nil
        state.onModeChange = nil
        close(legacyClient)
        close(commandClient)
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func presentOffscreenForInteraction(_ window: NSWindow) {
    window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
    window.orderBack(nil)
}

private func makeConnectedServerFixture() throws -> ConnectedServerFixture {
    let directory = URL(fileURLWithPath: "/tmp")
        .appendingPathComponent("vbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socketURL = directory.appendingPathComponent("voicelayer.sock")
    let state = VoiceState()
    let server = SocketServer(state: state, socketPath: socketURL.path)
    server.start()
    guard waitForSocket(at: socketURL.path) else {
        throw NSError(domain: "SocketServerTests", code: 1)
    }
    let legacyClient = try connectUnixSocket(path: socketURL.path)
    let commandClient = try connectUnixSocket(path: socketURL.path)
    try writeLine(#"{"type":"client_hello","role":"mcp-server","pid":111,"accepts_commands":false}"#, to: legacyClient)
    try writeLine(#"{"type":"client_hello","role":"mcp-daemon","pid":222,"accepts_commands":true}"#, to: commandClient)
    guard waitForConnectionStatus(state, connected: true, timeout: 1) else {
        throw NSError(domain: "SocketServerTests", code: 4)
    }
    return ConnectedServerFixture(
        directory: directory,
        state: state,
        server: server,
        legacyClient: legacyClient,
        commandClient: commandClient
    )
}

@MainActor
private func dispatchRuntimeKey(virtualKey: CGKeyCode, router: VoiceBarCommandRouter) {
    guard let event = CGEvent(
        keyboardEventSource: CGEventSource(stateID: .privateState),
        virtualKey: virtualKey,
        keyDown: true
    ) else {
        XCTFail("could not construct runtime key event")
        return
    }
    let action = hotkeyAction(
        type: event.type,
        keycode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags,
        autorepeat: 0,
        targetKeycodes: HotkeyManager.defaultTargetKeycodes,
        useModifierMode: false,
        cancellationIsActive: router.shouldHandleEscape
    )
    dispatchHotkeyAction(
        action,
        onKeyDown: { router.handleHotkeyHoldStart() },
        onCancel: { router.handleEscape() }
    )
}

@MainActor
private func click(_ host: NSView, at point: NSPoint, in window: NSWindow) throws {
    guard host.hitTest(point) != nil else {
        throw NSError(domain: "SocketServerTests", code: 2)
    }
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
    ))
    let up = try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
        windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
    ))
    window.sendEvent(down)
    window.sendEvent(up)
}

@MainActor
private func clickSpeakingStop(
    _ host: NSView,
    in window: NSWindow,
    playbackClient: Int32
) throws -> String {
    var x = host.bounds.maxX - 10
    let y = host.bounds.height > VoiceBarNotchContract.topHeight
        ? CGFloat(23)
        : host.bounds.midY
    while x >= host.bounds.midX {
        try click(host, at: NSPoint(x: x, y: y), in: window)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        if let line = try readLine(from: playbackClient, timeout: 0.02) {
            return line
        }
        x -= 3
    }
    throw NSError(domain: "SocketServerTests", code: 3)
}

@MainActor
private func clickRecordingStop(
    _ host: NSView,
    in window: NSWindow,
    state: VoiceState
) throws {
    var x = host.bounds.minX + 10
    while x <= host.bounds.midX {
        try click(host, at: NSPoint(x: x, y: host.bounds.midY), in: window)
        if waitForCondition(timeout: 0.15, condition: { state.mode == .transcribing }) {
            return
        }
        x += 3
    }
    throw NSError(domain: "SocketServerTests", code: 5)
}

private func waitForSocket(at path: String, timeout: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return FileManager.default.fileExists(atPath: path)
}

private func connectUnixSocket(path: String, timeout: TimeInterval = 1) throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    var lastReadinessError: NSError?
    repeat {
        do {
            return try connectUnixSocketOnce(path: path)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain &&
            (error.code == Int(ECONNREFUSED) || error.code == Int(ENOENT)) {
            lastReadinessError = error
            Thread.sleep(forTimeInterval: 0.01)
        }
    } while Date() < deadline
    throw lastReadinessError ?? NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
}

private func connectUnixSocketOnce(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dest, src.baseAddress!, src.count)
            }
        }
    }

    let result = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            connect(fd, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    return fd
}

private func writeLine(_ line: String, to fd: Int32) throws {
    let payload = Array((line + "\n").utf8)
    var offset = 0
    while offset < payload.count {
        let written = payload.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!.advanced(by: offset), payload.count - offset)
        }
        if written > 0 {
            offset += written
            continue
        }
        if written == -1, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func waitForConnectionStatus(_ state: VoiceState, connected: Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if state.isConnected == connected {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return state.isConnected == connected
}

private func waitForMode(_ state: VoiceState, mode: VoiceMode, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if state.mode == mode {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return state.mode == mode
}

private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

private func readLine(from fd: Int32, timeout: TimeInterval) throws -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1024)

    while Date() < deadline {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            bytes.append(contentsOf: buffer[0 ..< count])
            if let newlineIndex = bytes.firstIndex(of: 10) {
                return String(bytes: bytes[0 ..< newlineIndex], encoding: .utf8)
            }
        } else if count == -1, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    return nil
}

private func readLines(from fd: Int32, count expectedCount: Int, timeout: TimeInterval) throws -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes: [UInt8] = []
    var lines: [String] = []
    var buffer = [UInt8](repeating: 0, count: 1024)

    while Date() < deadline, lines.count < expectedCount {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            bytes.append(contentsOf: buffer[0 ..< count])
            while let newlineIndex = bytes.firstIndex(of: 10) {
                if let line = String(bytes: bytes[0 ..< newlineIndex], encoding: .utf8) {
                    lines.append(line)
                }
                bytes.removeSubrange(...newlineIndex)
            }
        } else if count == -1, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if lines.count < expectedCount {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    return lines
}
