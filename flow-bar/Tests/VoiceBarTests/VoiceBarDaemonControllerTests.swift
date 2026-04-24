@testable import VoiceBar
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

    func testActivationReturnsAlreadyRunningWhenProbeSucceeds() {
        let process = ProcessSpy()
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { true },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .alreadyRunning)
        XCTAssertFalse(process.didRun)
        XCTAssertFalse(controller.ownsLaunchedProcess)
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

        let externalProcess = ProcessSpy()
        let externalController = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in testLaunchConfiguration() },
            livenessProbe: { true },
            processFactory: { externalProcess }
        )
        _ = externalController.activateIfNeeded()

        externalController.stop()

        XCTAssertFalse(externalProcess.didTerminate)
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
}

private func testLaunchConfiguration() -> VoiceBarDaemonLaunchConfiguration {
    VoiceBarDaemonLaunchConfiguration(
        launchPath: testBunPath,
        arguments: ["run", testRepoDaemonPath],
        workingDirectory: testRepoRoot
    )
}

private final class ProcessSpy: Process, @unchecked Sendable {
    var didRun = false
    var didTerminate = false
    var capturedExecutableURL: URL?
    var capturedArguments: [String]?
    var capturedCurrentDirectoryURL: URL?
    var capturedEnvironment: [String: String]?
    var capturedTerminationHandler: (@Sendable (Process) -> Void)?

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

    override func run() throws {
        didRun = true
    }

    override func terminate() {
        didTerminate = true
    }
}
