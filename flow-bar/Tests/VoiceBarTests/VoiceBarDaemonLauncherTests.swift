@testable import VoiceBar
import XCTest

final class VoiceBarDaemonLauncherTests: XCTestCase {
    func testLauncherStartsDaemonProcessFromResolvedConfiguration() {
        let process = ProcessSpy()
        let launcher = VoiceBarDaemonLauncher(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in
                VoiceBarDaemonLaunchConfiguration(
                    launchPath: "/usr/bin/env",
                    arguments: ["bun", "run", "/tmp/voicelayer/src/daemon.ts"],
                    workingDirectory: "/tmp/voicelayer"
                )
            },
            processFactory: { process }
        )

        launcher.startIfNeeded()

        XCTAssertTrue(process.didRun)
        XCTAssertEqual(process.capturedExecutableURL?.path, "/usr/bin/env")
        XCTAssertEqual(process.capturedArguments ?? [], ["bun", "run", "/tmp/voicelayer/src/daemon.ts"])
        XCTAssertEqual(process.capturedCurrentDirectoryURL?.path, "/tmp/voicelayer")
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
