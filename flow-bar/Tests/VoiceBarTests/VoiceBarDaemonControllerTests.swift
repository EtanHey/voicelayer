@testable import VoiceBar
import XCTest

final class VoiceBarDaemonControllerTests: XCTestCase {
    func testDaemonControllerSkipsSpawnWhenDisableEnvSet() {
        setenv("DISABLE_VOICELAYER", "1", 1)
        defer { unsetenv("DISABLE_VOICELAYER") }

        let process = ProcessSpy()
        var livenessProbeCalls = 0
        let controller = VoiceBarDaemonController(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
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
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
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
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
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
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
            livenessProbe: { false },
            processFactory: { process }
        )

        let result = controller.activateIfNeeded()

        XCTAssertEqual(result, .launched)
        XCTAssertTrue(process.didRun)
        XCTAssertEqual(process.capturedExecutableURL?.path, "/usr/bin/env")
        XCTAssertEqual(process.capturedArguments ?? [], ["bun", "run", "/tmp/voicelayer/src/daemon.ts"])
        XCTAssertEqual(process.capturedCurrentDirectoryURL?.path, "/tmp/voicelayer")
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
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
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
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
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
            VoiceBarDaemonLaunchConfiguration.configuration(for: executableURL)
        )

        XCTAssertEqual(configuration.launchPath, "/usr/bin/env")
        XCTAssertEqual(configuration.arguments, [
            "bun",
            "run",
            "/tmp/voicelayer/src/daemon.ts",
        ])
        XCTAssertEqual(configuration.workingDirectory, "/tmp/voicelayer")
    }

    func testBundledAppLaunchesDaemonFromResourcesWhenPresent() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == "/Applications/VoiceBar.app/Contents/Resources/src/daemon.ts"
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, "/usr/bin/env")
        XCTAssertEqual(configuration.arguments, [
            "bun",
            "run",
            "/Applications/VoiceBar.app/Contents/Resources/src/daemon.ts",
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
    }

    func testFreshSessionLivenessProbeUsesDaemonPidPath() {
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/voicelayer-daemon.pid")
        XCTAssertEqual(
            VoiceBarDaemonLivenessProbe.freshSessionCheckCommand,
            "python3 -c \"import json, os, signal, sys; p='/tmp/voicelayer-daemon.pid'; data=json.load(open(p)); os.kill(int(data['pid']), 0)\""
        )
    }
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
