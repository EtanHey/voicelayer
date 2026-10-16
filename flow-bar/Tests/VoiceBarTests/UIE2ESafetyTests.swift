import Foundation
import OffscreenTestSupport
@testable import VoiceBar
import XCTest
import SwiftUI
import VoiceBarUI

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


    func testIdleFixtureRestoresTheSyntheticConnectionBaselineWithoutHardware() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.fixture("disconnected")
        XCTAssertFalse(model.voice.isConnected)
        let commandsBeforeIdleCleanup = model.commands.count

        model.fixture("idle")

        XCTAssertTrue(model.voice.isConnected, "Idle reset must restore the synthetic health baseline")
        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertEqual(model.commands.count, commandsBeforeIdleCleanup,
            "Refreshing the fixture baseline must not send a command")
    }


    func testHistoryPaginationAddsVisibleFixtureRowsInBothScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        XCTAssertEqual(model.historyPage(limit: 100).loadedEntryCount, 2)
        let recordings = model.historyPage(limit: 200)
        XCTAssertEqual(recordings.loadedEntryCount, 3)
        XCTAssertEqual(recordings.groups.last?.entries.last?.transcript, "QA loaded transcript")
        XCTAssertFalse(recordings.hasMore)
        XCTAssertEqual(model.askHistoryPage(limit: 100).loadedEntryCount, 1)
        let asks = model.askHistoryPage(limit: 200)
        XCTAssertEqual(asks.loadedEntryCount, 2)
        XCTAssertEqual(asks.groups.last?.entries.last?.responseTranscript, "QA loaded response")
        XCTAssertFalse(asks.hasMore)
        XCTAssertTrue(model.events.contains("history-page:200"))
        XCTAssertTrue(model.events.contains("ask-history-page:200"))
    }


    func testRecentTranscriptIdentityKeepsTheRealControllerPayloadAndTitle() throws {
        let controller = PillContextMenuController()
        controller.recentTranscriptionEntriesProvider = {
            [.init(text: UIE2EModel.transcript, createdAt: Date(timeIntervalSince1970: 1_790_000_000))]
        }
        let menu = controller.makeMenu()
        let item = try XCTUnwrap(menu.items.flatMap { $0.submenu?.items ?? [] }.first {
            $0.representedObject as? String == UIE2EModel.transcript
        })
        let title = item.title
        UIE2EHost.identifyRecentMenuItems(menu)
        XCTAssertEqual(item.accessibilityIdentifier(), "uie2e-recent-qa-recording")
        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.representedObject as? String, UIE2EModel.transcript)
        XCTAssertNotNil(item.target)
        XCTAssertNotNil(item.action)
    }

    func testMicrophoneMenuIdentitySurvivesNativeSubtitleWithoutReplacingItsActions() throws {
        let controller = PillContextMenuController()
        controller.defaultMicrophoneNameProvider = { "QA microphone A" }
        let menu = controller.makeMenu()
        let parent = try XCTUnwrap(menu.items.first { $0.title == "Microphone" })
        let children = try XCTUnwrap(parent.submenu).items
        let change = try XCTUnwrap(children.first { $0.action != nil })
        let title = change.title, action = change.action
        UIE2EHost.identifyRecentMenuItems(menu)
        XCTAssertEqual(parent.accessibilityIdentifier(), "uie2e-microphone-menu")
        XCTAssertEqual(parent.title, "Microphone")
        XCTAssertEqual(children.first?.accessibilityIdentifier(), "uie2e-microphone-default")
        XCTAssertEqual(change.accessibilityIdentifier(), "uie2e-microphone-change")
        XCTAssertEqual(change.title, title)
        XCTAssertEqual(change.action, action)
        XCTAssertNotNil(change.target)
    }

    func testTrackingMenuKeepsItsAnchorPanelFrameUntilTheMenuCloses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let host = UIE2EHost(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        host.model.fixture("speaking")
        let view = NSHostingView(rootView: BarView(state: host.model.voice,
            commandRouter: VoiceBarCommandRouter(voiceState: host.model.voice), onOpenSettings: {}, onOpenHistory: {}))
        host.pill = FloatingPillPanel(content: view)
        host.pill.setFrame(CGRect(x: -1000, y: -1000, width: 680, height: 180), display: false)
        let anchor = host.pill.frame
        let menu = NSMenu()
        host.menuWillOpen(menu)
        host.updatePillLayout()
        XCTAssertEqual(host.pill.frame, anchor, "Resizing a tracking menu's anchor can dismiss the real menu")
        host.menuDidClose(menu)
        XCTAssertNotEqual(host.pill.frame, anchor, "Deferred layout must be applied after menu close")
    }

    func testQAStatusButtonHasItsOwnAXIdentityRatherThanTheProductionImageName() {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VoiceBar")
        UIE2EHost.identifyStatusButton(button)
        XCTAssertEqual(button.accessibilityLabel(), "VoiceBar QA")
        XCTAssertEqual(button.accessibilityIdentifier(), "uie2e-status-item")
    }

    func testVisibilityChangesReachThePanelOwnerInsteadOfAStaticRootView() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        var hidden: [Bool] = []
        model.onVisibilityChange = { hidden.append($0) }
        model.hidden = true; model.hidden = false; model.hidden = true
        XCTAssertEqual(hidden, [true, false, true])
    }



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
