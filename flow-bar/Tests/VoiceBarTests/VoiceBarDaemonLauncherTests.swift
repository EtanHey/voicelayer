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
    func testUnbundledDaemonCannotInheritAnotherBuildTag() {
        let inherited = ["VOICEBAR_VERSION": "stale", "VOICEBAR_GIT_COMMIT": "stale",
            "VOICEBAR_BUILD_TIME_UTC": "stale", "VOICEBAR_BUILD_SOURCE": "stale", "VOICEBAR_GIT_DESCRIBE": "stale"]
        for info: [String: Any] in [[:], ["CFBundleShortVersionString": "foreign"], ["GitCommit": "unknown"]] {
            let env = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(from: inherited, path: "/fixture", bundleInfo: info)
            for key in inherited.keys { XCTAssertNil(env[key], key) }
        }
    }
    func testBundleFactsReplaceInheritedBuildIdentity() {
        let expected = ["VOICEBAR_VERSION": "2.3.0", "VOICEBAR_GIT_COMMIT": String(repeating: "a", count: 40),
            "VOICEBAR_BUILD_TIME_UTC": "2026-11-08T00:00:00Z", "VOICEBAR_BUILD_SOURCE": "VoiceBar.Info.plist",
            "VOICEBAR_GIT_DESCRIBE": "v2.3.0-dirty"]
        let info = ["CFBundleShortVersionString": expected["VOICEBAR_VERSION"]!, "GitCommit": expected["VOICEBAR_GIT_COMMIT"]!,
            "BuildTimeUTC": expected["VOICEBAR_BUILD_TIME_UTC"]!, "GitDescribe": expected["VOICEBAR_GIT_DESCRIBE"]!]
        for bundleInfo in [info, [:]] {
            let env = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(from: expected.merging(["VOICEBAR_GIT_DESCRIBE": "stale"]) { _, new in new }, path: "/fixture", bundleInfo: bundleInfo)
            for key in expected.keys { XCTAssertEqual(env[key], bundleInfo.isEmpty ? nil : expected[key], key) }
            XCTAssertEqual(env["VOICEBAR_DAEMON_SOURCE"], "unknown")
        }
    }
    func testSelectedCheckoutDaemonOriginReachesSpawnEnvironment() throws {
        let previous = ProcessInfo.processInfo.environment["VOICEBAR_DAEMON_SOURCE"]
        setenv("VOICEBAR_DAEMON_SOURCE", "stale", 1)
        defer { if let previous { setenv("VOICEBAR_DAEMON_SOURCE", previous, 1) } else { unsetenv("VOICEBAR_DAEMON_SOURCE") } }
        for source in ["checkout", "bundled", "homebrew"] {
            let executable = URL(fileURLWithPath: source == "checkout" ? "/fixture/flow-bar/.build/VoiceBar" : "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")
            let picked = try XCTUnwrap(VoiceBarDaemonLaunchConfiguration.configuration(for: executable,
                fileExists: { $0 == launcherTestBunPath || $0 == (source == "bundled" ? launcherTestBundledDaemonPath : launcherTestHomebrewDaemonPath) },
                fileData: { launcherTestVersionData[$0] }, environment: [:]))
            let process = ProcessSpy()
            let launcher = VoiceBarDaemonLauncher(executableURLProvider: { executable }, configurationProvider: { _ in picked },
                socketBindingAllowed: { _ in true }, processFactory: { process })
            launcher.startIfNeeded()
            XCTAssertTrue(process.didRun)
            XCTAssertEqual(process.capturedEnvironment?["VOICEBAR_DAEMON_SOURCE"], source)
        }
    }
    func testDefaultSocketsAreRefusedBeforeSpawningFromNonResidentBundle() {
        let keys = ["VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "QA_VOICE_SOCKET_PATH",
                    "QA_VOICE_MCP_SOCKET_PATH", "DISABLE_VOICELAYER", "QA_VOICE_DISABLE_FLAG_PATH"]
        let previous = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for key in keys {
            unsetenv(key)
        }
        setenv("QA_VOICE_DISABLE_FLAG_PATH", "/tmp/iso-no-disable-" + UUID().uuidString, 1)
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let process = ProcessSpy()
        let owner = VoiceBarDaemonLauncher(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/QA/VoiceBar.app/Contents/MacOS/VoiceBar") },
            configurationProvider: { _ in launcherTestLaunchConfiguration() },
            processFactory: { process }
        )
        owner.startIfNeeded()

        XCTAssertFalse(process.didRun)
    }

    func testLauncherStartsDaemonProcessFromResolvedConfiguration() {
        let process = ProcessSpy()
        let launcher = VoiceBarDaemonLauncher(
            executableURLProvider: { URL(fileURLWithPath: "/tmp/voicelayer/flow-bar/.build/debug/VoiceBar") },
            configurationProvider: { _ in launcherTestLaunchConfiguration() },
            socketBindingAllowed: { _ in true }, // These lifecycle tests use ProcessSpy, not a socket owner.
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
            "VOICEBAR_QA_PRESERVE_OVERRIDES": ProcessInfo.processInfo.environment["VOICEBAR_QA_PRESERVE_OVERRIDES"],
            "QA_VOICEBAR_PRESERVE_TEST_OVERRIDES": ProcessInfo.processInfo
                .environment["QA_VOICEBAR_PRESERVE_TEST_OVERRIDES"],
        ]
        unsetenv("VOICEBAR_QA_PRESERVE_OVERRIDES")
        unsetenv("QA_VOICEBAR_PRESERVE_TEST_OVERRIDES")
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
            socketBindingAllowed: { _ in true }, // These lifecycle tests use ProcessSpy, not a socket owner.
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
                },
                environment: [:]
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
                },
                environment: [:]
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestBundledDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
    }

    func testInstalledAppPrefersItsBundledDaemonWhenHomebrewPackageAlsoMatches() throws {
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
                },
                environment: [:]
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestBundledDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, "/Applications/VoiceBar.app/Contents/Resources")
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

    func testInstalledAppFallsBackToMatchingHomebrewPackageWhenBundledDaemonIsMissing() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar")

        let configuration = try XCTUnwrap(
            VoiceBarDaemonLaunchConfiguration.configuration(
                for: executableURL,
                fileExists: { path in
                    path == launcherTestBunPath ||
                        path == launcherTestHomebrewDaemonPath
                },
                fileData: { path in launcherTestVersionData[path] },
                environment: [:]
            )
        )

        XCTAssertEqual(configuration.launchPath, launcherTestBunPath)
        XCTAssertEqual(configuration.arguments, [
            "run",
            launcherTestHomebrewDaemonPath,
        ])
        XCTAssertEqual(configuration.workingDirectory, launcherTestHomebrewPackageRoot)
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
