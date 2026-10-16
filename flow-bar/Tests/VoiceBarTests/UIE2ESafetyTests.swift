import Foundation
@testable import VoiceBar
import XCTest

final class UIE2ESafetyTests: XCTestCase {
    func testRejectsMissingOrUnmarkedSandbox() throws {
        XCTAssertThrowsError(try UIE2ESandbox(environment: [:]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["VOICEBAR_UIE2E_ROOT": root.path]
        XCTAssertThrowsError(try UIE2ESandbox(environment: env))
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        XCTAssertEqual(try UIE2ESandbox(environment: env).root, root.resolvingSymlinksInPath())
    }

    func testNeverAcceptsUserHomeOrLiveSocketLocations() {
        for path in [NSHomeDirectory(), "/", "/tmp", "/Applications/VoiceBar.app"] {
            XCTAssertThrowsError(try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": path]))
        }
    }
}

@MainActor
final class UIE2EFixtureCommandTests: XCTestCase {
    func testAskPasteSinkReceivesExactlyTheResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        let before = model.events.count
        model.pasteHistoryTranscript("QA response")
        XCTAssertEqual(Array(model.events.dropFirst(before)), ["history-paste:QA response"])
    }

    func testAtomicVoiceAndProcessingAcksReachProductionState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.voice.setTTSProfile(.short, engine: "clone", voice: "ben-c1")
        XCTAssertEqual(model.voice.speechControls?.profiles[.short]?.voice.effective, "ben-c1")
        XCTAssertTrue(model.voice.speechPending.isEmpty)
        model.voice.setProcessingSetting(.modelPolish, true)
        XCTAssertEqual(model.voice.modelsSettingsState.polishControls?.modelPolish.effective, .on)
        XCTAssertTrue(model.voice.processingPending.isEmpty)
        model.voice.setWhisperResidency(.notLoaded)
        XCTAssertEqual(model.voice.modelsSettingsState.residency, .notLoaded)
        model.voice.setWhisperResidency(.loaded)
        XCTAssertEqual(model.voice.modelsSettingsState.residency, .loaded)
    }
}

final class UIE2ELaunchPolicyTests: XCTestCase {
    func testMarkedBundleRejectsMissingModeEvenWithIsolatedSockets() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["VOICEBAR_UIE2E_ROOT": root.path,
                   "VOICELAYER_SOCKET_PATH": root.appendingPathComponent("v.sock").path,
                   "VOICELAYER_MCP_SOCKET_PATH": root.appendingPathComponent("m.sock").path]
        XCTAssertTrue(SocketBindingPolicy.allowsEnvironment(env))
        XCTAssertThrowsError(try UIE2ELaunchPolicy.resolve(
            bundleIdentifier: "com.voicelayer.voicebar.uie2e", marker: true,
            environment: env, confirmMute: { XCTFail("Invalid mode must fail before mute or startup"); return true }))
        var invalid = env; invalid["VOICEBAR_UIE2E"] = "0"
        XCTAssertThrowsError(try UIE2ELaunchPolicy.resolve(
            bundleIdentifier: "com.voicelayer.voicebar.uie2e", marker: true,
            environment: invalid, confirmMute: { true }))
    }

    func testMarkedBundleRejectsFailedMuteAndProbeFailure() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["VOICEBAR_UIE2E_ROOT": root.path, "VOICEBAR_UIE2E": "1"]
        for probe: () throws -> Bool in [{ false }, { throw CocoaError(.fileReadUnknown) }] {
            XCTAssertThrowsError(try UIE2ELaunchPolicy.resolve(
                bundleIdentifier: "com.voicelayer.voicebar.uie2e", marker: true,
                environment: env, confirmMute: probe))
        }
    }

    func testOnlyOrdinaryUnmarkedBundleMayUseProductionStartup() throws {
        XCTAssertEqual(try UIE2ELaunchPolicy.resolve(bundleIdentifier: "com.voicelayer.voicebar", marker: nil,
            environment: [:], confirmMute: { XCTFail("Production must not run QA probe"); return false }), .production)
        XCTAssertThrowsError(try UIE2ELaunchPolicy.resolve(bundleIdentifier: "com.voicelayer.voicebar.uie2e", marker: nil,
            environment: [:], confirmMute: { true }))
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try UIE2ELaunchPolicy.resolve(bundleIdentifier: "com.voicelayer.voicebar.uie2e", marker: true,
            environment: ["VOICEBAR_UIE2E_ROOT": root.path, "VOICEBAR_UIE2E": "1"], confirmMute: { true }), .fixture)
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        return root
    }
}
