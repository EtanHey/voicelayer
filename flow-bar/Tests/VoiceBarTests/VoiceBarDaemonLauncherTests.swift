@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

private let launcherTestBunPath = "/opt/homebrew/bin/bun"
private let launcherTestRepoRoot = "/tmp/voicelayer"
private let launcherTestRepoDaemonPath = "\(launcherTestRepoRoot)/src/mcp-server-daemon.ts"
private let launcherTestHomebrewPackageRoot = "/opt/homebrew/opt/voicelayer/libexec/lib/node_modules/voicelayer-mcp"
private let launcherTestHomebrewDaemonPath = "\(launcherTestHomebrewPackageRoot)/src/mcp-server-daemon.ts"
private let launcherTestHomebrewPackageJSONPath = "\(launcherTestHomebrewPackageRoot)/package.json"
private let launcherTestBundledDaemonPath = "/Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts"
private let launcherTestInstalledInfoPlistPath = "/Applications/VoiceBar.app/Contents/Info.plist"

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

    func testLauncherUsesSanitizedDaemonEnvironmentWithEnrichedPath() throws {
        let previousValues: [String: String?] = [
            "QA_VOICE_SOCKET_PATH": ProcessInfo.processInfo.environment["QA_VOICE_SOCKET_PATH"],
            "QA_VOICE_MCP_SOCKET_PATH": ProcessInfo.processInfo.environment["QA_VOICE_MCP_SOCKET_PATH"],
            "CODEX_CI": ProcessInfo.processInfo.environment["CODEX_CI"],
        ]
        setenv("QA_VOICE_SOCKET_PATH", "/tmp/test-voicebar.sock", 1)
        setenv("QA_VOICE_MCP_SOCKET_PATH", "/tmp/test-mcp.sock", 1)
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
        let launcher = VoiceBarDaemonLauncher(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in launcherTestLaunchConfiguration() },
            processFactory: { process }
        )

        launcher.startIfNeeded()

        let environment = try XCTUnwrap(process.capturedEnvironment)
        XCTAssertNil(environment["QA_VOICE_SOCKET_PATH"])
        XCTAssertNil(environment["QA_VOICE_MCP_SOCKET_PATH"])
        XCTAssertNil(environment["CODEX_CI"])
        XCTAssertNil(environment["VOICELAYER_ALLOW_SOCKET_RECLAIM"])
        let path = try XCTUnwrap(environment["PATH"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
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

    func testInstalledAppPrefersHomebrewPackageDaemonWhenAvailable() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath ||
                        path == launcherTestHomebrewDaemonPath ||
                        path == launcherTestBundledDaemonPath
                },
                fileData: { path in
                    launcherTestVersionData[path]
                }
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestHomebrewDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, launcherTestHomebrewPackageRoot)
    }

    func testIsolatedQABuildPrefersBundledDaemonWhenHomebrewVersionMatches() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/VoiceBar-dev.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath ||
                        path == launcherTestHomebrewDaemonPath ||
                        path == "/tmp/VoiceBar-dev.app/Contents/Resources/src/mcp-server-daemon.ts"
                },
                fileData: { path in
                    if path == "/tmp/VoiceBar-dev.app/Contents/Info.plist" {
                        return launcherInfoPlistData(version: "2.1.10")
                    }
                    return launcherTestVersionData[path]
                },
                environment: ["VOICEBAR_QA_PRESERVE_OVERRIDES": "1"]
            )
        )

        XCTAssertEqual(configuration.arguments, [
            "run",
            "/tmp/VoiceBar-dev.app/Contents/Resources/src/mcp-server-daemon.ts",
        ])
        XCTAssertEqual(configuration.workingDirectory, "/tmp/VoiceBar-dev.app/Contents/Resources")
    }

    func testInstalledAppFallsBackToBundledDaemonWhenHomebrewPackageVersionIsStale() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath ||
                        path == launcherTestHomebrewDaemonPath ||
                        path == launcherTestBundledDaemonPath
                },
                fileData: { path in
                    if path == launcherTestHomebrewPackageJSONPath {
                        return launcherPackageJSONData(version: "2.1.9")
                    }
                    return launcherTestVersionData[path]
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

private var launcherTestVersionData: [String: Data] {
    [
        launcherTestInstalledInfoPlistPath: launcherInfoPlistData(version: "2.1.10"),
        launcherTestHomebrewPackageJSONPath: launcherPackageJSONData(version: "2.1.10"),
    ]
}

private func launcherPackageJSONData(version: String) -> Data {
    Data(#"{"name":"voicelayer-mcp","version":"\#(version)"}"#.utf8)
}

private func launcherInfoPlistData(version: String) -> Data {
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

private final class ProcessSpy: Process, @unchecked Sendable {
    var didRun = false
    var capturedExecutableURL: URL?
    var capturedArguments: [String]?
    var capturedCurrentDirectoryURL: URL?
    var capturedEnvironment: [String: String]?

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

    override var isRunning: Bool {
        didRun
    }

    override func run() throws {
        didRun = true
    }
}
