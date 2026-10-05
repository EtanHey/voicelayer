import Darwin
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class SocketBindingPolicyTests: XCTestCase {
    func testBindingMatrixForBothResidentSockets() {
        for path in SocketBindingPolicy.livePaths {
            XCTAssertTrue(allowed("/Applications/VoiceBar.app", path))
            XCTAssertFalse(allowed("/tmp/QA/VoiceBar.app", path))
            XCTAssertTrue(allowed("/tmp/QA/VoiceBar.app", "/tmp/isolated/v.sock"))
            XCTAssertTrue(allowed("/Applications/VoiceBar.app", "/tmp/isolated/m.sock"))
            XCTAssertFalse(allowed("/Applications/VoiceBar.app", path, qa: true))
            XCTAssertFalse(allowed("/Applications/VoiceBar.app", path, env: ["VOICEBAR_QA_BUILD": "1"]))
            XCTAssertFalse(allowed("/tmp/QA/VoiceBar.app", path, env: ["VOICELAYER_SOCKET_PATH": path]))
            XCTAssertFalse(allowed("/tmp/QA/VoiceBar.app", "/private" + path))
            XCTAssertFalse(allowed(
                "/tmp/QA/VoiceBar.app",
                "/tmp/qa/../" + URL(fileURLWithPath: path).lastPathComponent
            ))
        }
    }

    func testSymlinkAliasCannotMakeResidentSocketLookIsolated() throws {
        // Both protected targets are private stand-ins, independent of resident socket state.
        let directory = URL(fileURLWithPath: "/tmp/iso-alias-" + UUID().uuidString)
        let targetDirectory = directory.appendingPathComponent("protected")
        let aliasDirectory = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: targetDirectory)
        for file in ["voicelayer.sock", "voicelayer-mcp.sock"] {
            let target = targetDirectory.appendingPathComponent(file)
            let alias = aliasDirectory.appendingPathComponent(file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            for targetExists in [false, true] {
                if targetExists { try Data().write(to: target) }
                XCTAssertFalse(SocketBindingPolicy.allowsRuntimeBind(
                    bundlePath: "/tmp/QA/VoiceBar.app", socketPath: alias.path, environment: [:],
                    qaBuild: false, protectedPaths: [target.path]
                ), "alias must be refused when target exists=\(targetExists)")
                XCTAssertTrue(SocketBindingPolicy.allowsRuntimeBind(
                    bundlePath: "/Applications/VoiceBar.app", socketPath: alias.path, environment: [:],
                    qaBuild: false, protectedPaths: [target.path]
                ))
                XCTAssertTrue(SocketBindingPolicy.allowsRuntimeBind(
                    bundlePath: "/tmp/QA/VoiceBar.app",
                    socketPath: aliasDirectory.appendingPathComponent("isolated.sock").path, environment: [:],
                    qaBuild: false, protectedPaths: [target.path]
                ))
            }
        }
    }

    func testChildIsolationMustSurviveEnvironmentSanitization() {
        let overrides = ["QA_VOICE_SOCKET_PATH": "/tmp/isolated/v.sock",
                         "QA_VOICE_MCP_SOCKET_PATH": "/tmp/isolated/m.sock"]
        let stripped = VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(from: overrides, path: "/usr/bin")
        XCTAssertFalse(SocketBindingPolicy.allowsEnvironment(stripped, bundlePath: "/tmp/QA/VoiceBar.app"))
        var preserved = overrides
        preserved["VOICEBAR_QA_PRESERVE_OVERRIDES"] = "1"
        XCTAssertTrue(SocketBindingPolicy.allowsEnvironment(
            VoiceBarDaemonEnvironment.sanitizedDaemonEnvironment(from: preserved, path: "/usr/bin"),
            bundlePath: "/tmp/QA/VoiceBar.app"
        ))
        XCTAssertFalse(SocketBindingPolicy.allowsEnvironment(
            ["VOICELAYER_SOCKET_PATH": "/tmp/isolated/v.sock"], bundlePath: "/tmp/QA/VoiceBar.app"
        ))
        XCTAssertFalse(SocketBindingPolicy.allowsEnvironment(
            ["VOICELAYER_MCP_SOCKET_PATH": "/tmp/isolated/m.sock"], bundlePath: "/tmp/QA/VoiceBar.app"
        ))
        XCTAssertTrue(SocketBindingPolicy.allowsEnvironment(
            [:],
            bundlePath: "/Applications/VoiceBar.app",
            qaBuild: false
        ))
    }

    func testCanonicalOverridesWinAndQAOverridesRemainSupported() {
        for (key, qaKey, resolve) in [
            ("VOICELAYER_SOCKET_PATH", "QA_VOICE_SOCKET_PATH", { VoiceLayerPaths.socketPath }),
            ("VOICELAYER_MCP_SOCKET_PATH", "QA_VOICE_MCP_SOCKET_PATH", { VoiceLayerPaths.mcpSocketPath }),
        ] {
            let old = [key: ProcessInfo.processInfo.environment[key], qaKey: ProcessInfo.processInfo.environment[qaKey]]
            defer {
                for (name, value) in old {
                    if let value { setenv(name, value, 1) } else { unsetenv(name) }
                }
            }
            setenv(key, "/tmp/isolated/canonical.sock", 1)
            setenv(qaKey, "/tmp/isolated/qa.sock", 1)
            XCTAssertEqual(resolve(), "/tmp/isolated/canonical.sock")
            if key == "VOICELAYER_SOCKET_PATH" { XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance) }
            setenv(key, "   ", 1)
            XCTAssertEqual(resolve(), "/tmp/isolated/qa.sock")
            unsetenv(key)
            XCTAssertEqual(resolve(), "/tmp/isolated/qa.sock")
        }
    }

    func testRefusedStartPreservesExistingListeningSocket() throws {
        // Model the protected live path with a real disposable listener. Never touch /tmp/voicelayer*.sock.
        let directory = URL(fileURLWithPath: "/tmp/iso-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                bytes.withUnsafeBufferPointer { _ = memcpy(dest, $0.baseAddress!, $0.count) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            ) }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        let refused = expectation(description: "binding refused before unlink")
        let server = SocketServer(state: VoiceState(), socketPath: path, bindAllowed: {
            SocketBindingPolicy.allowsBind(bundlePath: "/tmp/QA/VoiceBar.app", socketPath: path,
                                           environment: [:], qaBuild: false, protectedPaths: [path])
        }, onBindRefused: { refused.fulfill() })
        server.start()
        defer { server.stop() }
        wait(for: [refused], timeout: 1)
        let after = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after)
        XCTAssertTrue(VoiceBarDaemonLivenessProbe.isSocketLive(at: path))
    }

    private func allowed(_ bundle: String, _ path: String, qa: Bool = false, env: [String: String] = [:]) -> Bool {
        SocketBindingPolicy.allowsBind(bundlePath: bundle, socketPath: path, environment: env, qaBuild: qa)
    }
}
