@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

private let testBunPath = "/opt/homebrew/bin/bun"
private let testRepoRoot = "/tmp/voicelayer"
private let testRepoDaemonPath = "\(testRepoRoot)/src/mcp-server-daemon.ts"
private let testBundledDaemonPath = "/Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts"

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

    func testActivationStillLaunchesOwnedChildWhenExternalProbeSucceeds() {
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
            "QA_VOICE_RECORDING_STATE_PATH": ProcessInfo.processInfo.environment["QA_VOICE_RECORDING_STATE_PATH"],
            "CODEX_CI": ProcessInfo.processInfo.environment["CODEX_CI"],
        ]
        setenv("QA_VOICE_CHUNKED_STT", "1", 1)
        setenv("QA_VOICE_SOCKET_PATH", "/tmp/test-voicebar.sock", 1)
        setenv("QA_VOICE_MCP_SOCKET_PATH", "/tmp/test-mcp.sock", 1)
        setenv("QA_VOICE_RECORDING_STATE_PATH", "/tmp/test-recording-state.json", 1)
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
        XCTAssertNil(process.capturedEnvironment?["QA_VOICE_RECORDING_STATE_PATH"])
        XCTAssertNil(process.capturedEnvironment?["CODEX_CI"])
        XCTAssertEqual(process.capturedEnvironment?["VOICELAYER_ALLOW_SOCKET_RECLAIM"], "1")
        XCTAssertNotNil(process.capturedEnvironment?["PATH"])
    }

    func testDaemonLaunchPreservesOnlyPathOverridesForIsolatedQAMode() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "VOICEBAR_QA_PRESERVE_OVERRIDES": "1",
                "QA_VOICEBAR_PRESERVE_TEST_OVERRIDES": "1",
                "QA_VOICE_SOCKET_PATH": "/tmp/qa-voicebar.sock",
                "QA_VOICE_MCP_SOCKET_PATH": "/tmp/qa-mcp.sock",
                "QA_VOICE_MCP_PID_PATH": "/tmp/qa-mcp.pid",
                "QA_VOICE_RECORDING_STATE_PATH": "/tmp/qa-recording-state.json",
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
        XCTAssertEqual(environment["QA_VOICE_RECORDING_STATE_PATH"], "/tmp/qa-recording-state.json")
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

    func testUnexpectedCleanExitSchedulesRelaunch() {
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

        XCTAssertTrue(secondProcess.didRun)
        XCTAssertTrue(controller.ownsLaunchedProcess)
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

        XCTAssertTrue(scheduledBlocks.filter { $0.delay < 300 }.isEmpty)
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

        let restartDelays = scheduledBlocks.map(\.delay).filter { $0 < 300 }
        XCTAssertEqual(restartDelays, [1, 2])
        XCTAssertFalse(secondProcess.didRun)
    }

    func testScheduledRestartSkipsWhenAnotherActivationAlreadyLaunchedChild() {
        let firstProcess = ProcessSpy()
        firstProcess.capturedTerminationStatus = 0
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
        drainMainQueue(until: { scheduledBlocks.map(\.delay).filter { $0 < 300 }.count == 2 })

        let restartDelays = scheduledBlocks.map(\.delay).filter { $0 < 300 }
        XCTAssertEqual(restartDelays, [1, 1])
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

        let restartDelays = scheduledBlocks.map(\.delay).filter { $0 < 300 }
        XCTAssertEqual(restartDelays, [1])
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

    func testFreshSessionLivenessProbeUsesDaemonPidPath() {
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/voicelayer-mcp.pid")
        XCTAssertEqual(
            VoiceBarDaemonLivenessProbe.freshSessionCheckCommand,
            "python3 -c \"import json, os, signal, sys; p='/tmp/voicelayer-mcp.pid'; data=json.load(open(p)); os.kill(int(data['pid']), 0)\""
        )
    }

    func testVoiceLayerPathsRespectQAOverrides() {
        let previousValues: [String: String?] = [
            VoiceLayerPaths.socketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.socketOverrideEnvironmentVariable],
            VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable],
            VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable],
            VoiceLayerPaths.retainedRecordingOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.retainedRecordingOverrideEnvironmentVariable],
        ]
        setenv(VoiceLayerPaths.socketOverrideEnvironmentVariable, "/tmp/qa-voicebar.sock", 1)
        setenv(VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable, "/tmp/qa-mcp.sock", 1)
        setenv(VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable, "/tmp/qa-mcp.pid", 1)
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
        XCTAssertEqual(VoiceLayerPaths.retainedRecordingPath, "/tmp/qa-last.wav")
        XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance)
    }

    func testVoiceLayerPathsPreferPublicSocketOverride() {
        let previousValues: [String: String?] = [
            VoiceLayerPaths.socketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.socketOverrideEnvironmentVariable],
            VoiceLayerPaths.legacySocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.legacySocketOverrideEnvironmentVariable],
            VoiceLayerPaths.devInstanceEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.devInstanceEnvironmentVariable],
        ]
        setenv(VoiceLayerPaths.socketOverrideEnvironmentVariable, "/tmp/public-voicebar.sock", 1)
        setenv(VoiceLayerPaths.legacySocketOverrideEnvironmentVariable, "/tmp/qa-voicebar.sock", 1)
        setenv(VoiceLayerPaths.devInstanceEnvironmentVariable, "1", 1)
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        XCTAssertEqual(VoiceLayerPaths.socketPath, "/tmp/public-voicebar.sock")
        XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance)
    }

    func testVoiceLayerPathsUseIsolatedDefaultsForDevInstance() {
        let previousValues: [String: String?] = [
            VoiceLayerPaths.socketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.socketOverrideEnvironmentVariable],
            VoiceLayerPaths.legacySocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.legacySocketOverrideEnvironmentVariable],
            VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.mcpSocketOverrideEnvironmentVariable],
            VoiceLayerPaths.legacyMcpSocketOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.legacyMcpSocketOverrideEnvironmentVariable],
            VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.daemonPIDOverrideEnvironmentVariable],
            VoiceLayerPaths.legacyDaemonPIDOverrideEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.legacyDaemonPIDOverrideEnvironmentVariable],
            VoiceLayerPaths.devInstanceEnvironmentVariable: ProcessInfo.processInfo
                .environment[VoiceLayerPaths.devInstanceEnvironmentVariable],
        ]
        for (key, _) in previousValues {
            unsetenv(key)
        }
        setenv(VoiceLayerPaths.devInstanceEnvironmentVariable, "1", 1)
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        XCTAssertEqual(VoiceLayerPaths.socketPath, "/tmp/voicelayer-dev.sock")
        XCTAssertEqual(VoiceLayerPaths.mcpSocketPath, "/tmp/voicelayer-dev-mcp.sock")
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/voicelayer-dev-mcp.pid")
        XCTAssertTrue(VoiceLayerPaths.isDevInstance)
        XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance)
    }

    func testDaemonLaunchPreservesPublicPathOverridesForDevInstance() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "VOICELAYER_DEV_INSTANCE": "1",
                "VOICELAYER_SOCKET_PATH": "/tmp/public-voicebar.sock",
                "VOICELAYER_MCP_SOCKET_PATH": "/tmp/public-mcp.sock",
                "VOICELAYER_MCP_PID_PATH": "/tmp/public-mcp.pid",
                "VOICELAYER_RETAINED_RECORDING_PATH": "/tmp/public-last.wav",
                "QA_VOICE_SOCKET_PATH": "/tmp/qa-voicebar.sock",
                "QA_VOICE_MCP_SOCKET_PATH": "/tmp/qa-mcp.sock",
                "QA_VOICE_CHUNKED_STT": "1",
                "CODEX_CI": "1",
                "VOICELAYER_ALLOW_SOCKET_RECLAIM": "1",
            ],
            path: "/tmp/bin"
        )

        XCTAssertEqual(environment["VOICELAYER_DEV_INSTANCE"], "1")
        XCTAssertEqual(environment["VOICELAYER_SOCKET_PATH"], "/tmp/public-voicebar.sock")
        XCTAssertEqual(environment["VOICELAYER_MCP_SOCKET_PATH"], "/tmp/public-mcp.sock")
        XCTAssertEqual(environment["VOICELAYER_MCP_PID_PATH"], "/tmp/public-mcp.pid")
        XCTAssertEqual(environment["VOICELAYER_RETAINED_RECORDING_PATH"], "/tmp/public-last.wav")
        XCTAssertEqual(environment["QA_VOICE_SOCKET_PATH"], "/tmp/qa-voicebar.sock")
        XCTAssertEqual(environment["QA_VOICE_MCP_SOCKET_PATH"], "/tmp/qa-mcp.sock")
        XCTAssertNil(environment["QA_VOICE_CHUNKED_STT"])
        XCTAssertNil(environment["CODEX_CI"])
        XCTAssertNil(environment["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        XCTAssertEqual(environment["PATH"], "/tmp/bin")
    }

    func testDaemonLaunchPreservesPublicPathOverridesWithoutDevFlag() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "VOICELAYER_SOCKET_PATH": "/tmp/public-voicebar.sock",
                "VOICELAYER_MCP_SOCKET_PATH": "/tmp/public-mcp.sock",
                "VOICELAYER_MCP_PID_PATH": "/tmp/public-mcp.pid",
                "VOICELAYER_RETAINED_RECORDING_PATH": "/tmp/public-last.wav",
                "VOICELAYER_RECORDING_STATE_PATH": "/tmp/public-recording-state.json",
                "VOICELAYER_ALLOW_SOCKET_RECLAIM": "1",
                "QA_VOICE_CHUNKED_STT": "1",
            ],
            path: "/tmp/bin"
        )

        XCTAssertEqual(environment["VOICELAYER_SOCKET_PATH"], "/tmp/public-voicebar.sock")
        XCTAssertEqual(environment["VOICELAYER_MCP_SOCKET_PATH"], "/tmp/public-mcp.sock")
        XCTAssertEqual(environment["VOICELAYER_MCP_PID_PATH"], "/tmp/public-mcp.pid")
        XCTAssertEqual(environment["VOICELAYER_RETAINED_RECORDING_PATH"], "/tmp/public-last.wav")
        XCTAssertEqual(environment["VOICELAYER_RECORDING_STATE_PATH"], "/tmp/public-recording-state.json")
        XCTAssertNil(environment["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        XCTAssertNil(environment["QA_VOICE_CHUNKED_STT"])
        XCTAssertEqual(environment["PATH"], "/tmp/bin")
    }

    func testDaemonLaunchPreservesLegacyPathOverridesForDevInstance() {
        let environment = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(
            from: [
                "VOICELAYER_DEV_INSTANCE": "1",
                "QA_VOICE_SOCKET_PATH": "/tmp/qa-voicebar.sock",
                "QA_VOICE_MCP_SOCKET_PATH": "/tmp/qa-mcp.sock",
                "QA_VOICE_MCP_PID_PATH": "/tmp/qa-mcp.pid",
                "QA_VOICE_RECORDING_STATE_PATH": "/tmp/qa-recording-state.json",
                "QA_VOICE_RETAINED_RECORDING_PATH": "/tmp/qa-last.wav",
                "QA_VOICE_DISABLE_FLAG_PATH": "/tmp/qa-disable.flag",
                "QA_VOICE_CHUNKED_STT": "1",
            ],
            path: "/tmp/bin"
        )

        XCTAssertEqual(environment["VOICELAYER_DEV_INSTANCE"], "1")
        XCTAssertEqual(environment["QA_VOICE_SOCKET_PATH"], "/tmp/qa-voicebar.sock")
        XCTAssertEqual(environment["QA_VOICE_MCP_SOCKET_PATH"], "/tmp/qa-mcp.sock")
        XCTAssertEqual(environment["QA_VOICE_MCP_PID_PATH"], "/tmp/qa-mcp.pid")
        XCTAssertEqual(environment["QA_VOICE_RECORDING_STATE_PATH"], "/tmp/qa-recording-state.json")
        XCTAssertEqual(environment["QA_VOICE_RETAINED_RECORDING_PATH"], "/tmp/qa-last.wav")
        XCTAssertEqual(environment["QA_VOICE_DISABLE_FLAG_PATH"], "/tmp/qa-disable.flag")
        XCTAssertNil(environment["QA_VOICE_CHUNKED_STT"])
        XCTAssertNil(environment["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        XCTAssertNil(environment["QA_VOICE_ALLOW_SOCKET_RECLAIM"])
        XCTAssertEqual(environment["PATH"], "/tmp/bin")
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
}

private func testLaunchConfiguration() -> VoiceBarDaemonLaunchConfiguration {
    VoiceBarDaemonLaunchConfiguration(
        launchPath: testBunPath,
        arguments: ["run", testRepoDaemonPath],
        workingDirectory: testRepoRoot
    )
}

private func temporaryPIDFile() -> String {
    "\(NSTemporaryDirectory())voicebar-daemon-\(UUID().uuidString).pid"
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
        4321
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
