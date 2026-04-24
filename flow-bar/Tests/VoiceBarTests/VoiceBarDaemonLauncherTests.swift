@testable import VoiceBar
import XCTest

private let launcherTestBunPath = "/opt/homebrew/bin/bun"
private let launcherTestRepoRoot = "/tmp/voicelayer"
private let launcherTestRepoDaemonPath = "\(launcherTestRepoRoot)/src/mcp-server-daemon.ts"
private let launcherTestBundledDaemonPath = "/Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts"

final class VoiceBarDaemonLauncherTests: XCTestCase {
    func testLauncherStartsDaemonProcessFromResolvedConfiguration() {
        let process = ProcessSpy()
        let launcher = VoiceBarDaemonLauncher(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in launcherTestLaunchConfiguration() },
            processFactory: { process }
        )

        launcher.startIfNeeded()

        XCTAssertTrue(process.didRun)
        XCTAssertEqual(process.capturedExecutableURL?.path, launcherTestBunPath)
        XCTAssertEqual(process.capturedArguments ?? [], ["run", launcherTestRepoDaemonPath])
        XCTAssertEqual(process.capturedCurrentDirectoryURL?.path, launcherTestRepoRoot)
    }

    func testCheckoutBuildLaunchesRepoDaemonWithBunRun() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath ||
                        path == "\(launcherTestRepoRoot)/flow-bar/Package.swift" ||
                        path == launcherTestRepoDaemonPath
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestRepoDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, launcherTestRepoRoot)
    }

    func testBundledAppLaunchesDaemonFromResourcesWhenPresent() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath || path == launcherTestBundledDaemonPath
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestBundledDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
    }
}

private func launcherTestLaunchConfiguration() -> VoiceBarDaemonLaunchConfiguration {
    VoiceBarDaemonLaunchConfiguration(
        launchPath: launcherTestBunPath,
        arguments: ["run", launcherTestRepoDaemonPath],
        workingDirectory: launcherTestRepoRoot
    )
}

private final class ProcessSpy: Process, @unchecked Sendable {
    var didRun = false
    var capturedExecutableURL: URL?
    var capturedArguments: [String]?
    var capturedCurrentDirectoryURL: URL?

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

    override var isRunning: Bool {
        didRun
    }

    override func run() throws {
        didRun = true
    }
}
