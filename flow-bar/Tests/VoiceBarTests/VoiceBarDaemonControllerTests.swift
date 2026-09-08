@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

private let testBunPath = "/opt/homebrew/bin/bun"
private let testRepoRoot = "/tmp/voicelayer"
private let testRepoDaemonPath = "\(testRepoRoot)/src/mcp-server-daemon.ts"
private let testHomebrewPackageRoot = "/opt/homebrew/opt/voicelayer/libexec/lib/node_modules/voicelayer-mcp"
private let testHomebrewDaemonPath = "\(testHomebrewPackageRoot)/src/mcp-server-daemon.ts"
private let testHomebrewPackageJSONPath = "\(testHomebrewPackageRoot)/package.json"
private let testBundledDaemonPath = "/Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts"
private let testInstalledInfoPlistPath = "/Applications/VoiceBar.app/Contents/Info.plist"

final class VoiceBarDaemonControllerTests: XCTestCase {
    func testDaemonControllerSkipsSpawnWhenDisableEnvSet() {
        setenv("DISABLE_VOICELAYER", "1", 1)
        defer { unsetenv("DISABLE_VOICELAYER") }

        let process = ProcessSpy()
        var livenessProbeCalls = 0
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: {
                livenessProbeCalls += 1
                return false
            },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(process.didRun)
        XCTAssertEqual(livenessProbeCalls, 0)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testDaemonControllerSkipsConnectWhenFlagFileExists() {
        let flagPath = "\(NSTemporaryDirectory())voicebar-disable-\(UUID().uuidString)"
        setenv("QA_VOICE_DISABLE_FLAG_PATH", flagPath, 1)
        FileManager.default.createFile(atPath: flagPath, contents: Data("disabled".utf8))
        defer {
            unsetenv("QA_VOICE_DISABLE_FLAG_PATH")
            try? FileManager.default.removeItem(atPath: flagPath)
        }

        let process = ProcessSpy()
        var livenessProbeCalls = 0
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: {
                livenessProbeCalls += 1
                return true
            },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(process.didRun)
        XCTAssertEqual(livenessProbeCalls, 0)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testActivationLaunchesOwnedChildEvenWhenStaleSocketLooksLive() {
        let process = ProcessSpy()
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { true },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .launched)
        XCTAssertTrue(process.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testActivationLaunchesDaemonWhenProbeFails() {
        let process = ProcessSpy()
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .launched)
        XCTAssertTrue(process.didRun)
        XCTAssertEqual(process.capturedExecutableURL?.path, testBunPath)
        XCTAssertEqual(process.capturedArguments ?? [], ["run", testRepoDaemonPath])
        XCTAssertEqual(process.capturedCurrentDirectoryURL?.path, testRepoRoot)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testDaemonLaunchDoesNotInheritExperimentalOrTestIsolationEnvironment() {
        let previousValues: [String: String?] = [
            "QA_VOICE_CHUNKED_STT": ProcessInfo.processInfo.environment["QA_VOICE_CHUNKED_STT"],
            "QA_VOICE_SOCKET_PATH": ProcessInfo.processInfo.environment["QA_VOICE_SOCKET_PATH"],
            "QA_VOICE_MCP_SOCKET_PATH": ProcessInfo.processInfo.environment["QA_VOICE_MCP_SOCKET_PATH"],
            "QA_VOICE_MCP_HEARTBEAT_PATH": ProcessInfo.processInfo.environment["QA_VOICE_MCP_HEARTBEAT_PATH"],
            "QA_VOICE_RECORDING_STATE_PATH": ProcessInfo.processInfo.environment["QA_VOICE_RECORDING_STATE_PATH"],
            "QA_VOICE_RECORDING_HOLD_PATH": ProcessInfo.processInfo.environment["QA_VOICE_RECORDING_HOLD_PATH"],
            "CODEX_CI": ProcessInfo.processInfo.environment["CODEX_CI"],
        ]
        setenv("QA_VOICE_CHUNKED_STT", "1", 1)
        setenv("QA_VOICE_SOCKET_PATH", "/tmp/test-voicebar.sock", 1)
        setenv("QA_VOICE_MCP_SOCKET_PATH", "/tmp/test-mcp.sock", 1)
        setenv("QA_VOICE_MCP_HEARTBEAT_PATH", "/tmp/test-mcp.heartbeat", 1)
        setenv("QA_VOICE_RECORDING_STATE_PATH", "/tmp/test-recording-state.json", 1)
        setenv("QA_VOICE_RECORDING_HOLD_PATH", "/tmp/test-recording-hold", 1)
        setenv("CODEX_CI", "1", 1)
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let process = ProcessSpy()
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { process }
        )

        _ = controller.activateIfNeeded()

        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_CHUNKED_STT"])
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_SOCKET_PATH"])
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_MCP_SOCKET_PATH"])
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_MCP_HEARTBEAT_PATH"])
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_RECORDING_STATE_PATH"])
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_RECORDING_HOLD_PATH"])
        XCTAssertNil(process.capturedEnvironment?["CODEX_CI"])
        XCTAssertNil(process.capturedEnvironment?["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        XCTAssertNotNil(process.capturedEnvironment?["PATH"])
        XCTAssertEqual(
            process.capturedEnvironment?["VOICEBAR_PARENT_PID"],
            String(ProcessInfo.processInfo.processIdentifier)
        )
    }

    func testDaemonLaunchPreservesOnlyPathOverridesForIsolatedQAMode() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "VOICEBAR_QA_PRESERVE_OVERRIDES": "1",
                "QA_VOICEBAR_PRESERVE_TEST_OVERRIDES": "1",
                "QA_VOICE_SOCKET_PATH": "/tmp/qa-voicebar.sock",
                "QA_VOICE_MCP_SOCKET_PATH": "/tmp/qa-mcp.sock",
                "QA_VOICE_MCP_PID_PATH": "/tmp/qa-mcp.pid",
                "QA_VOICE_MCP_HEARTBEAT_PATH": "/tmp/qa-mcp.heartbeat",
                "QA_VOICE_RECORDING_STATE_PATH": "/tmp/qa-recording-state.json",
                "QA_VOICE_RECORDING_HOLD_PATH": "/tmp/qa-recording-hold",
                "QA_VOICE_RETAINED_RECORDING_PATH": "/tmp/qa-last.wav",
                "QA_VOICE_DISABLE_FLAG_PATH": "/tmp/qa-disable.flag",
                "QA_VOICE_ALLOW_SOCKET_RECLAIM": "1",
                "QA_VOICE_CHUNKED_STT": "1",
                "CODEX_CI": "1",
                "VOICELAYER_ALLOW_SOCKET_RECLAIM": "1",
            ],
            path: "/tmp/bin"
        )

        XCTAssertEqual(environment["QA_VOICE_SOCKET_PATH"], "/tmp/qa-voicebar.sock")
        XCTAssertEqual(environment["QA_VOICE_MCP_SOCKET_PATH"], "/tmp/qa-mcp.sock")
        XCTAssertEqual(environment["QA_VOICE_MCP_PID_PATH"], "/tmp/qa-mcp.pid")
        XCTAssertEqual(environment["QA_VOICE_MCP_HEARTBEAT_PATH"], "/tmp/qa-mcp.heartbeat")
        XCTAssertEqual(environment["QA_VOICE_RECORDING_STATE_PATH"], "/tmp/qa-recording-state.json")
        XCTAssertEqual(environment["QA_VOICE_RECORDING_HOLD_PATH"], "/tmp/qa-recording-hold")
        XCTAssertEqual(environment["QA_VOICE_RETAINED_RECORDING_PATH"], "/tmp/qa-last.wav")
        XCTAssertEqual(environment["QA_VOICE_DISABLE_FLAG_PATH"], "/tmp/qa-disable.flag")
        XCTAssertNil(environment["VOICEBAR_QA_PRESERVE_OVERRIDES"])
        XCTAssertNil(environment["QA_VOICEBAR_PRESERVE_TEST_OVERRIDES"])
        XCTAssertNil(environment["QA_VOICE_ALLOW_SOCKET_RECLAIM"])
        XCTAssertNil(environment["QA_VOICE_CHUNKED_STT"])
        XCTAssertNil(environment["CODEX_CI"])
        XCTAssertNil(environment["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        XCTAssertEqual(environment["PATH"], "/tmp/bin")
    }

    func testCleanExitWithoutDisableFlagSchedulesRelaunch() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 0
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1])
        XCTAssertTrue(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testCleanExitWithDisableFlagIsTerminal() {
        let flagPath = "\(NSTemporaryDirectory())voicebar-disable-\(UUID().uuidString)"
        setenv("QA_VOICE_DISABLE_FLAG_PATH", flagPath, 1)
        defer {
            unsetenv("QA_VOICE_DISABLE_FLAG_PATH")
            try? FileManager.default.removeItem(atPath: flagPath)
        }

        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 0
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()
        FileManager.default.createFile(atPath: flagPath, contents: Data("disabled".utf8))

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { !controller.ownsLaunchedProcess })

        XCTAssertTrue(restartDelays(from: scheduledBlocks).isEmpty)
        XCTAssertFalse(secondProcess.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testCleanExitWithLiveExternalDaemonDoesNotScheduleRelaunch() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 0
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { true },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { !controller.ownsLaunchedProcess })

        XCTAssertTrue(restartDelays(from: scheduledBlocks).isEmpty)
        XCTAssertFalse(secondProcess.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testHeartbeatCheckIsScheduledForOwnedChild() {
        let process = ProcessSpy()
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { process },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )

        _ = controller.activateIfNeeded()

        XCTAssertTrue(scheduledBlocks.contains { $0.delay == 5 })
        XCTAssertFalse(process.didReceiveTerminate)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testAdvancingHeartbeatKeepsOwnedChildRunning() {
        let process = ProcessSpy()
        var sequence = 1
        var now = Date(timeIntervalSince1970: 1000)
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            heartbeatReader: {
                VoiceBarDaemonHeartbeat(pid: process.processIdentifier, sequence: sequence)
            },
            dateProvider: { now },
            processFactory: { process },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        for index in 0 ..< 3 {
            now = now.addingTimeInterval(5)
            sequence += 1
            scheduledBlocks.filter { $0.delay == 5 }[index].block()
        }

        XCTAssertFalse(process.didReceiveTerminate)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(controller.ownsLaunchedProcess)
        XCTAssertTrue(restartDelays(from: scheduledBlocks).isEmpty)
    }

    func testHeartbeatGapAboveHalfThresholdLogsSequencesAndElapsedTime() {
        let process = ProcessSpy()
        var sequence = 7
        var now = Date(timeIntervalSince1970: 1000)
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        var loggedGaps: [(previous: Int, current: Int, elapsed: TimeInterval)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            heartbeatReader: {
                VoiceBarDaemonHeartbeat(pid: process.processIdentifier, sequence: sequence)
            },
            heartbeatGapLogger: { previous, current, elapsed in
                loggedGaps.append((previous, current, elapsed))
            },
            dateProvider: { now },
            processFactory: { process },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        now = now.addingTimeInterval(5)
        scheduledBlocks.filter { $0.delay == 5 }[0].block()
        now = now.addingTimeInterval(16)
        sequence = 8
        scheduledBlocks.filter { $0.delay == 5 }[1].block()

        XCTAssertEqual(loggedGaps.count, 1)
        XCTAssertEqual(loggedGaps[0].previous, 7)
        XCTAssertEqual(loggedGaps[0].current, 8)
        XCTAssertEqual(loggedGaps[0].elapsed, 16)
        XCTAssertTrue(process.isRunning)
    }

    func testStaleHeartbeatForceKillsAndRestartsOwnedChild() {
        let firstProcess = ProcessSpy(processIdentifier: 4321)
        firstProcess.ignoresTerminate = true
        let secondProcess = ProcessSpy(processIdentifier: 4322)
        var processQueue = [firstProcess, secondProcess]
        var now = Date(timeIntervalSince1970: 2000)
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        var forceKilledPIDs: [Int32] = []
        var loggedGaps: [(previous: Int, current: Int, elapsed: TimeInterval)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            heartbeatReader: {
                VoiceBarDaemonHeartbeat(pid: firstProcess.processIdentifier, sequence: 7)
            },
            heartbeatGapLogger: { previous, current, elapsed in
                loggedGaps.append((previous, current, elapsed))
            },
            dateProvider: { now },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) },
            processExitWaiter: { _, _ in false },
            forceKillProcess: { pid in
                forceKilledPIDs.append(pid)
                firstProcess.forceExit()
            }
        )
        _ = controller.activateIfNeeded()

        for index in 0 ..< 6 {
            now = now.addingTimeInterval(5)
            scheduledBlocks.filter { $0.delay == 5 }[index].block()
        }
        XCTAssertFalse(firstProcess.didReceiveTerminate)

        now = now.addingTimeInterval(5)
        scheduledBlocks.filter { $0.delay == 5 }[6].block()
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertTrue(firstProcess.didReceiveTerminate)
        XCTAssertEqual(forceKilledPIDs, [firstProcess.processIdentifier])
        XCTAssertEqual(loggedGaps.count, 1)
        XCTAssertEqual(loggedGaps[0].previous, 7)
        XCTAssertEqual(loggedGaps[0].current, 7)
        XCTAssertEqual(loggedGaps[0].elapsed, 20)
        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1])
        XCTAssertTrue(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testStaleHeartbeatDoesNotRestartWhenOwnedChildSurvivesForceKill() {
        let firstProcess = ProcessSpy(processIdentifier: 4321)
        firstProcess.ignoresTerminate = true
        let secondProcess = ProcessSpy(processIdentifier: 4322)
        var processQueue = [firstProcess, secondProcess]
        var now = Date(timeIntervalSince1970: 2000)
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        var forceKilledPIDs: [Int32] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            heartbeatReader: {
                VoiceBarDaemonHeartbeat(pid: firstProcess.processIdentifier, sequence: 7)
            },
            dateProvider: { now },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) },
            processExitWaiter: { _, _ in false },
            forceKillProcess: { pid in forceKilledPIDs.append(pid) }
        )
        _ = controller.activateIfNeeded()

        for index in 0 ..< 6 {
            now = now.addingTimeInterval(5)
            scheduledBlocks.filter { $0.delay == 5 }[index].block()
        }
        XCTAssertFalse(firstProcess.didReceiveTerminate)

        now = now.addingTimeInterval(5)
        scheduledBlocks.filter { $0.delay == 5 }[6].block()

        XCTAssertTrue(firstProcess.didReceiveTerminate)
        XCTAssertEqual(forceKilledPIDs, [firstProcess.processIdentifier])
        XCTAssertTrue(firstProcess.isRunning)
        XCTAssertTrue(controller.ownsLaunchedProcess)
        XCTAssertTrue(restartDelays(from: scheduledBlocks).isEmpty)
        XCTAssertFalse(secondProcess.didRun)
        XCTAssertEqual(scheduledBlocks.filter { $0.delay == 5 }.count, 8)
    }

    func testMissingHeartbeatUsesStartupGraceBeforeRestart() {
        let firstProcess = ProcessSpy()
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var now = Date(timeIntervalSince1970: 3000)
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            heartbeatReader: { nil },
            dateProvider: { now },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        for index in 0 ..< 5 {
            now = now.addingTimeInterval(5)
            scheduledBlocks.filter { $0.delay == 5 }[index].block()
        }
        XCTAssertFalse(firstProcess.didReceiveTerminate)

        now = now.addingTimeInterval(5)
        scheduledBlocks.filter { $0.delay == 5 }[5].block()
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertTrue(firstProcess.didReceiveTerminate)
        XCTAssertTrue(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testBrokenMicSignalRespawnsOwnedChildAfterSecondConsecutiveFailure() {
        let firstProcess = ProcessSpy()
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        var promptedMessages: [String] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) },
            microphonePermissionPrompter: { message in promptedMessages.append(message) }
        )
        _ = controller.activateIfNeeded()

        controller.handleCaptureFailure(type: "broken-mic")

        XCTAssertFalse(firstProcess.didReceiveTerminate)
        XCTAssertEqual(restartDelays(from: scheduledBlocks), [])
        XCTAssertFalse(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)

        controller.handleCaptureFailure(type: "broken-mic")
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertTrue(firstProcess.didReceiveTerminate)
        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1])
        XCTAssertTrue(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
        XCTAssertEqual(promptedMessages.count, 1)
    }

    func testCrashWhileDisabledDoesNotScheduleRelaunch() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        setenv("DISABLE_VOICELAYER", "1", 1)
        defer { unsetenv("DISABLE_VOICELAYER") }
        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { !controller.ownsLaunchedProcess })

        XCTAssertTrue(restartDelays(from: scheduledBlocks).isEmpty)
        XCTAssertFalse(secondProcess.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testFailedRestartAttemptReschedulesWithBackoff() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var launchConfiguration: VoiceBarDaemonLaunchConfiguration? = testLaunchConfiguration()
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in launchConfiguration },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        launchConfiguration = nil
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1, 2])
        XCTAssertFalse(secondProcess.didRun)
    }

    func testScheduledRestartSkipsWhenExternalDaemonBecomesLiveDuringBackoff() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var externalDaemonIsLive = false
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { externalDaemonIsLive },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        externalDaemonIsLive = true
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertFalse(secondProcess.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testScheduledRestartSkipsWhenAnotherActivationAlreadyLaunchedChild() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        let thirdProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess, thirdProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        _ = controller.activateIfNeeded()
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()

        XCTAssertTrue(secondProcess.didRun)
        XCTAssertFalse(thirdProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
    }

    func testRestartCounterResetsAfterStableDaemonPeriod() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        secondProcess.capturedTerminationStatus = 1
        let thirdProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess, thirdProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })
        scheduledBlocks.first(where: { $0.delay == 1 })?.block()
        scheduledBlocks.last(where: { $0.delay == 300 })?.block()
        secondProcess.capturedTerminationHandler?(secondProcess)
        drainMainQueue(until: { restartDelays(from: scheduledBlocks).count == 2 })

        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1, 1])
    }

    func testDuplicateTerminationsScheduleOnlyOneRestart() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 1
        let secondProcess = ProcessSpy()
        var processQueue = [firstProcess, secondProcess]
        var scheduledBlocks: [(delay: TimeInterval, block: () -> Void)] = []
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { processQueue.removeFirst() },
            restartScheduler: { delay, block in scheduledBlocks.append((delay, block)) }
        )
        _ = controller.activateIfNeeded()

        firstProcess.capturedTerminationHandler?(firstProcess)
        firstProcess.capturedTerminationHandler?(firstProcess)
        drainMainQueue(until: { scheduledBlocks.contains { $0.delay == 1 } })

        XCTAssertEqual(restartDelays(from: scheduledBlocks), [1])
    }

    func testActivationReturnsUnavailableWithoutLaunchConfiguration() {
        let process = ProcessSpy()
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in nil },
            livenessProbe: { false },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(process.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
    }

    func testStopOnlyTerminatesOwnedProcess() {
        let ownedProcess = ProcessSpy()
        let ownedController = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { ownedProcess }
        )
        _ = ownedController.activateIfNeeded()

        ownedController.stop()

        XCTAssertTrue(ownedProcess.didTerminate)
        XCTAssertFalse(ownedController.ownsLaunchedProcess)

        XCTAssertFalse(ownedProcess.isRunning)
    }

    func testStopForceKillsOwnedProcessIfTerminateDoesNotExit() {
        let ownedProcess = ProcessSpy()
        ownedProcess.ignoresTerminate = true
        var waitedTimeouts: [TimeInterval] = []
        var forceKilledPIDs: [Int32] = []
        let ownedController = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { false },
            processFactory: { ownedProcess },
            processExitWaiter: { _, timeout in
                waitedTimeouts.append(timeout)
                return false
            },
            forceKillProcess: { pid in
                forceKilledPIDs.append(pid)
                ownedProcess.forceExit()
            }
        )
        _ = ownedController.activateIfNeeded()

        ownedController.stop()

        XCTAssertTrue(ownedProcess.didReceiveTerminate)
        XCTAssertEqual(forceKilledPIDs, [ownedProcess.processIdentifier])
        XCTAssertEqual(waitedTimeouts.count, 2)
        XCTAssertFalse(ownedController.ownsLaunchedProcess)
        XCTAssertFalse(ownedProcess.isRunning)
    }

    func testCheckoutBuildLaunchesRepoDaemonWithBunRun() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == testBunPath ||
                        path == "\(testRepoRoot)/flow-bar/Package.swift" ||
                        path == testRepoDaemonPath
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, testBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            testRepoDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, testRepoRoot)
    }

    func testBundledAppLaunchesDaemonFromResourcesWhenPresent() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == testBunPath || path == testBundledDaemonPath
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, testBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            testBundledDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
    }

    func testInstalledAppPrefersItsBundledDaemonWhenHomebrewPackageAlsoMatches() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == testBunPath ||
                        path == testHomebrewDaemonPath ||
                        path == testBundledDaemonPath
                },
                fileData: { path in
                    testVersionData[path]
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, testBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            testBundledDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
    }

    func testInstalledAppFallsBackToMatchingHomebrewPackageWhenBundledDaemonIsMissing() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == testBunPath ||
                        path == testHomebrewDaemonPath
                },
                fileData: { path in testVersionData[path] }
            )
        )

        XCTAssertEqual(configuration.launchPath, testBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            testHomebrewDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, testHomebrewPackageRoot)
    }

    func testFreshSessionLivenessProbeUsesDaemonPidPath() {
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/voicelayer-mcp.pid")
        XCTAssertEqual(
            VoiceBarDaemonLivenessProbe.freshSessionCheckCommand,
            "python3 -c \"import json, os, signal, sys; p='/tmp/voicelayer-mcp.pid'; data=json.load(open(p)); os.kill(int(data['pid']), 0)\""
        )
    }

    func testVoiceLayerPathsRespectQAOverrides() {
        let previousValues: [String: String?] = [
            VoiceLayerPaths.stateDirectoryOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.stateDirectoryOverrideEnvironmentVariable],
            VoiceLayerPaths.socketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.socketOverrideEnvironmentVariable],
            VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable],
            VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable],
            VoiceLayerPaths.daemonHeartbeatOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.daemonHeartbeatOverrideEnvironmentVariable],
            VoiceLayerPaths.retainedRecordingOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.retainedRecordingOverrideEnvironmentVariable],
        ]
        setenv(VoiceLayerPaths.stateDirectoryOverrideEnvironmentVariable, "/tmp/qa-state", 1)
        setenv(VoiceLayerPaths.socketOverrideEnvironmentVariable, "/tmp/qa-voicebar.sock", 1)
        setenv(VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable, "/tmp/qa-mcp.sock", 1)
        setenv(VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable, "/tmp/qa-mcp.pid", 1)
        setenv(VoiceLayerPaths.daemonHeartbeatOverrideEnvironmentVariable, "/tmp/qa-mcp.heartbeat", 1)
        setenv(VoiceLayerPaths.retainedRecordingOverrideEnvironmentVariable, "/tmp/qa-last.wav", 1)
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        XCTAssertEqual(VoiceLayerPaths.socketPath, "/tmp/qa-voicebar.sock")
        XCTAssertEqual(VoiceLayerPaths.mcpSocketPath, "/tmp/qa-mcp.sock")
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/qa-mcp.pid")
        XCTAssertEqual(VoiceLayerPaths.stateDirectory, "/tmp/qa-state")
        XCTAssertEqual(VoiceLayerPaths.daemonHeartbeatPath, "/tmp/qa-mcp.heartbeat")
        XCTAssertEqual(VoiceLayerPaths.retainedRecordingPath, "/tmp/qa-last.wav")
        XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance)
    }

    func testDaemonHeartbeatPathUsesOverriddenStateDirectoryByDefault() {
        let stateKey = VoiceLayerPaths.stateDirectoryOverrideEnvironmentVariable
        let heartbeatKey = VoiceLayerPaths.daemonHeartbeatOverrideEnvironmentVariable
        let pidKey = VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable
        let socketKey = VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable
        let canonicalSocketKey = "VOICELAYER_MCP_SOCKET_PATH"
        let previousValues: [String: String?] = [
            stateKey: ProcessInfo.processInfo.environment[stateKey],
            heartbeatKey: ProcessInfo.processInfo.environment[heartbeatKey],
            pidKey: ProcessInfo.processInfo.environment[pidKey],
            socketKey: ProcessInfo.processInfo.environment[socketKey],
            canonicalSocketKey: ProcessInfo.processInfo.environment[canonicalSocketKey],
        ]
        setenv(stateKey, "/tmp/qa-state", 1)
        unsetenv(heartbeatKey)
        unsetenv(pidKey)
        unsetenv(socketKey)
        unsetenv(canonicalSocketKey)
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        XCTAssertEqual(VoiceLayerPaths.daemonHeartbeatPath, "/tmp/qa-state/voicelayer-mcp.heartbeat")
    }

    func testDaemonHeartbeatPathFollowsIsolatedPidAndSocketOverrides() {
        XCTAssertEqual(
            VoiceLayerPaths.mcpHeartbeatPath(environment: [
                "VOICELAYER_STATE_DIR": "/tmp/live-state",
                "QA_VOICE_MCP_PID_PATH": "/tmp/qa-run/voicelayer-mcp.pid",
            ]),
            "/tmp/qa-run/voicelayer-mcp.heartbeat"
        )
        XCTAssertEqual(
            VoiceLayerPaths.mcpHeartbeatPath(environment: [
                "VOICELAYER_STATE_DIR": "/tmp/live-state",
                "VOICELAYER_MCP_SOCKET_PATH": "/tmp/qa-run/m.sock",
            ]),
            "/tmp/qa-run/m.sock.heartbeat"
        )
        XCTAssertEqual(
            VoiceLayerPaths.mcpHeartbeatPath(environment: [
                "VOICELAYER_STATE_DIR": "/tmp/live-state",
                "QA_VOICE_MCP_HEARTBEAT_PATH": "/tmp/explicit.heartbeat",
                "QA_VOICE_MCP_PID_PATH": "/tmp/qa-run/voicelayer-mcp.pid",
            ]),
            "/tmp/explicit.heartbeat"
        )
    }

    func testSanitizedChildHeartbeatPathIgnoresLeftoverVoiceBarHeartbeatOverride() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "QA_VOICE_MCP_HEARTBEAT_PATH": "/tmp/leftover.heartbeat",
                "VOICELAYER_STATE_DIR": "/tmp/qa-state",
            ],
            path: "/tmp/bin"
        )

        XCTAssertNil(environment["QA_VOICE_MCP_HEARTBEAT_PATH"])
        XCTAssertEqual(
            VoiceLayerPaths.mcpHeartbeatPath(environment: environment),
            "/tmp/qa-state/voicelayer-mcp.heartbeat"
        )
    }

    func testFreshSessionLivenessProbeRejectsAlivePidWithoutLiveSocket() throws {
        let pidFile = temporaryPIDFile()
        try Data("{\"pid\":\(ProcessInfo.processInfo.processIdentifier)}".utf8)
            .write(to: URL(fileURLWithPath: pidFile))
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        let isRunning = VoiceBarDaemonLivenessProbe.isDaemonRunning(
            pidFilePath: pidFile,
            socketPath: "/tmp/nonexistent-voicelayer-mcp.sock",
            socketProbe: { _ in false }
        )

        XCTAssertFalse(isRunning)
    }

    func testFreshSessionLivenessProbeAcceptsAlivePidWithLiveSocket() throws {
        let pidFile = temporaryPIDFile()
        try Data("{\"pid\":\(ProcessInfo.processInfo.processIdentifier)}".utf8)
            .write(to: URL(fileURLWithPath: pidFile))
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        let isRunning = VoiceBarDaemonLivenessProbe.isDaemonRunning(
            pidFilePath: pidFile,
            socketPath: "/tmp/test-live-voicelayer-mcp.sock",
            socketProbe: { _ in true }
        )

        XCTAssertTrue(isRunning)
    }

    func testFreshSessionLivenessProbeTreatsLiveSocketWithoutPidFileAsOccupied() {
        let pidFile = temporaryPIDFile()

        let isRunning = VoiceBarDaemonLivenessProbe.isDaemonRunning(
            pidFilePath: pidFile,
            socketPath: "/tmp/test-live-voicelayer-mcp.sock",
            socketProbe: { _ in true }
        )

        XCTAssertTrue(isRunning)
    }

    func testFreshSessionLivenessProbeIgnoresOwnedChildPid() throws {
        let pidFile = temporaryPIDFile()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        try Data("{\"pid\":\(currentPID)}".utf8)
            .write(to: URL(fileURLWithPath: pidFile))
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        let isRunning = VoiceBarDaemonLivenessProbe.isDaemonRunning(
            pidFilePath: pidFile,
            socketPath: "/tmp/test-live-voicelayer-mcp.sock",
            socketProbe: { _ in true },
            excludingPID: currentPID
        )

        XCTAssertFalse(isRunning)
    }
}

private func testLaunchConfiguration() -> VoiceBarDaemonLaunchConfiguration {
    VoiceBarDaemonLaunchConfiguration(
        launchPath: testBunPath,
        arguments: ["run", testRepoDaemonPath],
        workingDirectory: testRepoRoot
    )
}

private var testVersionData: [String: Data] {
    [
        testInstalledInfoPlistPath: infoPlistData(version: "2.1.10"),
        testHomebrewPackageJSONPath: packageJSONData(version: "2.1.10"),
    ]
}

private func packageJSONData(version: String) -> Data {
    Data(#"{"name":"voicelayer-mcp","version":"\#(version)"}"#.utf8)
}

private func infoPlistData(version: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleShortVersionString</key>
      <string>\(version)</string>
      <key>ReleaseVersion</key>
      <string>\(version)</string>
    </dict>
    </plist>
    """.utf8)
}

private func temporaryPIDFile() -> String {
    "\(NSTemporaryDirectory())voicebar-daemon-\(UUID().uuidString).pid"
}

private func restartDelays(from scheduledBlocks: [(delay: TimeInterval, block: () -> Void)]) -> [TimeInterval] {
    scheduledBlocks.map(\.delay).filter { $0 < 300 && $0 != 5 }
}

private func drainMainQueue(
    until condition: @escaping () -> Bool,
    timeout: TimeInterval = 1
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

private final class ProcessSpy: Process, @unchecked Sendable {
    private let stubProcessIdentifier: Int32
    var didRun = false
    var didTerminate = false
    var didReceiveTerminate = false
    var ignoresTerminate = false
    var capturedExecutableURL: URL?
    var capturedArguments: [String]?
    var capturedCurrentDirectoryURL: URL?
    var capturedEnvironment: [String: String]?
    var capturedTerminationHandler: (@Sendable (Process) -> Void)?
    var capturedTerminationStatus: Int32 = 1
    var capturedTerminationReason: Process.TerminationReason = .exit

    init(processIdentifier: Int32 = 4321) {
        stubProcessIdentifier = processIdentifier
        super.init()
    }

    override var executableURL: URL? {
        get { capturedExecutableURL }
        set { capturedExecutableURL = newValue }
    }

    override var arguments: [String]? {
        get { capturedArguments }
        set { capturedArguments = newValue }
    }

    override var currentDirectoryURL: URL? {
        get { capturedCurrentDirectoryURL }
        set { capturedCurrentDirectoryURL = newValue }
    }

    override var environment: [String: String]? {
        get { capturedEnvironment }
        set { capturedEnvironment = newValue }
    }

    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { capturedTerminationHandler }
        set { capturedTerminationHandler = newValue }
    }

    override var isRunning: Bool {
        didRun && !didTerminate
    }

    override var processIdentifier: Int32 {
        stubProcessIdentifier
    }

    override var terminationStatus: Int32 {
        capturedTerminationStatus
    }

    override var terminationReason: Process.TerminationReason {
        capturedTerminationReason
    }

    override func run() throws {
        didRun = true
    }

    override func terminate() {
        didReceiveTerminate = true
        if !ignoresTerminate {
            didTerminate = true
        }
    }

    func forceExit() {
        didTerminate = true
    }
}
