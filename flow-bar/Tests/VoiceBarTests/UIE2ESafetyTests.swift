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
    func testIdleFixtureClearsPreparingPlaybackWithoutSendingHardwareCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))

        model.fixture("preparing")
        XCTAssertEqual(model.voice.mode, .speaking)
        XCTAssertEqual(model.voice.teleprompterText, "Preparing speech…")
        XCTAssertTrue(model.commands.contains { $0["cmd"] as? String == "speak_text" &&
            $0["text"] as? String == "QA original selection" })
        let commandsBeforeIdleCleanup = model.commands.count

        model.fixture("idle")

        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertTrue(model.voice.statusText.isEmpty, "Idle must clear the preparing status text")
        XCTAssertNil(model.voice.teleprompterText, "Idle must remove stale preparing/readback teleprompter text")
        XCTAssertFalse(model.voice.isTeleprompterReadback)
        XCTAssertFalse(model.voice.isPlaybackDurationGrowing)
        XCTAssertEqual(model.commands.count, commandsBeforeIdleCleanup,
            "Fixture cleanup must not issue a stop or any other command")
        XCTAssertEqual(model.events.last, "fixture:idle")
        XCTAssertTrue(model.commands.allSatisfy { $0["cmd"] as? String == "speak_text" },
            "The model command sink records only synthetic commands and never reaches hardware")
    }

    func testIdleFixtureDismissesRetainedReadbackAndClearsHoverWithoutCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.voice.isHovering = true
        model.fixture("readback")
        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertTrue(model.voice.isTeleprompterReadback)
        XCTAssertEqual(model.voice.teleprompterText, "First QA item\nSecond QA item")
        let commandsBeforeIdleCleanup = model.commands.count

        model.fixture("idle")

        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertTrue(model.voice.statusText.isEmpty)
        XCTAssertNil(model.voice.teleprompterText, "Idle must dismiss the retained readback")
        XCTAssertFalse(model.voice.isTeleprompterReadback)
        XCTAssertFalse(model.voice.isHovering, "Idle fixture cleanup must release the synthetic pointer hold")
        XCTAssertEqual(model.commands.count, commandsBeforeIdleCleanup,
            "Dismissing an idle readback is local UI cleanup and must not send a command")
        XCTAssertEqual(model.events.last, "fixture:idle")
    }

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

    func testFeedbackFixtureHoldsItsPresentationThroughPointerExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.voice.setHoveringFromDebouncedPointer(false)
        for name in ["paste-not-inserted", "paste-unverified", "paste-partial"] {
            model.fixture(name)
            model.voice.setHoveringFromDebouncedPointer(false)
            XCTAssertEqual(UIE2EHost.panelLayout(for: model.voice).presentation.visualState, .compactStatus)
        }
        model.fixture("idle")
        model.voice.setHoveringFromDebouncedPointer(false)
        XCTAssertTrue(model.voice.isCollapsed, "Fixture hold must be released for normal idle")
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

    func testPreparingSelectionProbeUsesTheRealSelectionMethodWithNoNativeCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.fixture("preparing")
        XCTAssertEqual(model.voice.mode, .speaking)
        XCTAssertEqual(model.voice.statusText, "Preparing speech…")
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("preparing.json"))) as? [String: Any]
        XCTAssertEqual(receipt?["mode"] as? String, "speaking")
        XCTAssertEqual(receipt?["statusText"] as? String, "Preparing speech…")
        XCTAssertEqual(receipt?["durationGrowing"] as? Bool, true)
        XCTAssertEqual(receipt?["originalRequested"] as? Bool, true)
        XCTAssertTrue(model.commands.contains { $0["cmd"] as? String == "speak_text" &&
            $0["text"] as? String == "QA original selection" },
            "Preparing must retain a real original selection request before replacement")
        model.fixture("selection-replace")
        XCTAssertTrue(model.commands.contains { $0["cmd"] as? String == "stop" },
            "The current unmerged SEL1 contract stops; the probe must actually invoke speakSelection")

        // Cleanup happens only after the probe has asserted SEL1's real stop behavior.
        let commandsBeforeIdleCleanup = model.commands.count
        model.fixture("idle")
        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertTrue(model.voice.statusText.isEmpty)
        XCTAssertNil(model.voice.teleprompterText)
        XCTAssertFalse(model.voice.isTeleprompterReadback)
        XCTAssertEqual(model.commands.count, commandsBeforeIdleCleanup,
            "Fixture cleanup after the strict SEL1 probe must not issue another command")
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

    func testPillFrameContainsTheEntireRenderedSurfaceAcrossPlaybackStates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        let view = PillHostingView(rootView: BarView(state: model.voice,
            commandRouter: VoiceBarCommandRouter(voiceState: model.voice), onOpenSettings: {}, onOpenHistory: {},
            includesPanelOutsets: true))
        let panel = FloatingPillPanel(content: view)
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        var coreX: CGFloat?
        for state in ["speaking", "readback", "speaking", "finish", "idle"] {
            model.fixture(state)
            let layout = UIE2EHost.panelLayout(for: model.voice)
            UIE2EHost.fitPill(panel, layout: layout, in: screen)
            let expected = VoiceBarIsolatedCapturePlacement.frame(layout: layout, visibleFrame: screen,
                environment: [VoiceBarIsolatedCapturePlacement.topRightEnvironmentVariable: "1"])
            XCTAssertEqual(panel.frame, expected, "QA must use the production canvas and stable core anchor")
            XCTAssertEqual(panel.frame.size, layout.panelSize)
            XCTAssertTrue(screen.contains(panel.frame))
            let nextCoreX = panel.frame.minX + layout.visibleContentRect.minX + layout.presentation.geometry.coreMidX
            if let coreX { XCTAssertEqual(nextCoreX, coreX, accuracy: 0.01) }
            coreX = nextCoreX
        }
    }

    func testSpeakingFixtureRoutesReplayAndSeekOnlyToSyntheticSink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        model.voice.controlLayerEventWriter = { _, _ in }
        model.fixture("speaking")
        XCTAssertEqual(model.voice.mode, .speaking)
        XCTAssertTrue(model.voice.statusText.contains("\n"))
        model.voice.replay()
        model.voice.seek(offsetMs: 1000)
        XCTAssertTrue(model.events.contains("command:replay"))
        XCTAssertTrue(model.events.contains("command:seek"))
        model.fixture("readback")
        XCTAssertEqual(model.voice.mode, .idle)
        model.voice.replay()
        XCTAssertEqual(model.voice.mode, .speaking, "Silent replay must deliver the fixture speaking event for geometry probes")
        XCTAssertNil(model.voice.pendingIntent)
        model.fixture("finish")
        XCTAssertTrue(model.voice.isTeleprompterReadback)
        model.voice.replay()
        XCTAssertEqual(model.voice.mode, .speaking)
        model.voice.stop()
        XCTAssertEqual(model.voice.mode, .idle)
        XCTAssertFalse(model.voice.isTeleprompterReadback, "Production Stop clears retained text; do not fabricate an X state")

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

#if VOICEBAR_UIE2E_FOCUSED_338
@MainActor
final class UIE2EFocusedGalleryTests: XCTestCase {
    private func gallery() throws -> (UIE2EStateGallery, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        return (UIE2EStateGallery(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path])), root)
    }

    private var desktopMetrics: VoiceBarNotchScreenMetrics {
        .init(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080), safeAreaTop: 37,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1080, width: 760, height: 37),
            auxiliaryTopRightArea: CGRect(x: 968, y: 1080, width: 760, height: 37))
    }



    func testRealRoutesProduceEveryFamilyWithoutHardwareOrTransport() throws {
        let (gallery, root) = try gallery()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(gallery.items.count, 11)
        XCTAssertEqual(Set(gallery.items.map { $0.spec.family }), Set(["paste-feedback", "terminal", "busy", "selection-error"]))
        for item in gallery.items {
            XCTAssertEqual(item.actualText, item.spec.expectedText, item.spec.id)
            XCTAssertTrue(item.voice.isConnected)
            XCTAssertTrue(item.effects.commands.allSatisfy { $0 == "record" }, item.spec.id)
            XCTAssertEqual(item.effects.clipboardWrites, 0)
            XCTAssertEqual(item.effects.pasteShortcuts, 0)
            XCTAssertEqual(item.effects.selectionCaptures, item.spec.family == "selection-error" ? 1 : 0)
            XCTAssertEqual(item.effects.typed.count, item.spec.family == "terminal" ? 1 : 0)
            XCTAssertTrue(item.effects.typed.allSatisfy { $0 == UIE2EStateGallery.transcript })
        }
        XCTAssertEqual(gallery.item("paste-not-inserted").voice.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(gallery.item("paste-unverified").voice.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(gallery.item("paste-partial").voice.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(gallery.item("terminal-confirmation").voice.confirmationText, UIE2EStateGallery.transcript)
    }

    func testSharedClockGenerationUsesFreshModelsAndRealExpiry() async throws {
        let (gallery, root) = try gallery()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = gallery.items.map { $0.voice }
        gallery.startClocks()
        XCTAssertEqual(gallery.clockGeneration, 1)
        XCTAssertFalse(gallery.isPinned)
        let origin = try XCTUnwrap(gallery.clockOrigin)
        for (index, item) in gallery.items.enumerated() {
            XCTAssertFalse(previous[index] === item.voice, "Old confirmation timers must not shorten this generation")
            XCTAssertEqual(item.clockOrigin, origin)
            XCTAssertEqual(item.clockGeneration, 1)
        }
        try await Task.sleep(for: .milliseconds(2250))
        for item in gallery.items where item.spec.family == "busy" {
            XCTAssertFalse(item.voice.showsSelectionBusyNote)
            XCTAssertNotEqual(item.voice.mode, .disconnected)
        }
        let unaffected = gallery.items.filter { $0.spec.family != "busy" }.map { ObjectIdentifier($0.voice) }
        gallery.endSessions() // Re-arm genuinely expired notes and clear in the same MainActor batch.
        XCTAssertEqual(gallery.sessionEndBefore, Dictionary(uniqueKeysWithValues:
            gallery.items.filter { $0.spec.family == "busy" }.map { ($0.spec.id, $0.spec.expectedText) }))
        XCTAssertEqual(gallery.sessionEndGeneration, 1)
        XCTAssertEqual(gallery.clockGeneration, 1)
        XCTAssertEqual(gallery.clockOrigin, origin)
        XCTAssertEqual(gallery.items.filter { $0.spec.family != "busy" }.map { ObjectIdentifier($0.voice) }, unaffected)
        for item in gallery.items where item.spec.family == "selection-error" { XCTAssertNil(item.voice.confirmationText) }
        XCTAssertNotNil(gallery.item("terminal-confirmation").voice.confirmationText)
        try await Task.sleep(for: .milliseconds(3000))
        for item in gallery.items { XCTAssertNil(item.voice.confirmationText, item.spec.id) }
        gallery.observe(reason: "expiry-test")
        let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("gallery.json"))) as? [String: Any])
        XCTAssertEqual(receipt["reason"] as? String, "expiry-test")
        XCTAssertEqual(receipt["clockGeneration"] as? Int, 1)
    }

    func testPinnedBusyUsesAdmissionAndSessionEndActuallyClears() throws {
        let (gallery, root) = try gallery()
        defer { try? FileManager.default.removeItem(at: root) }
        gallery.refreshPinnedStates()
        XCTAssertTrue(gallery.isPinned)
        gallery.startClocks()
        for item in gallery.items where item.spec.family == "busy" {
            XCTAssertTrue(item.voice.showsSelectionBusyNote)
            XCTAssertEqual(item.effects.selectionCaptures, 0)
            XCTAssertTrue(item.effects.commands.isEmpty)
        }
        gallery.endSessions()
        for item in gallery.items where item.spec.family == "busy" {
            XCTAssertFalse(item.voice.showsSelectionBusyNote, item.spec.id)
            XCTAssertEqual(item.voice.hotkeyPhase, .idle)
            XCTAssertEqual(item.voice.mode, .idle)
        }
    }

    func testStaticHoldKeepsModelsAndCapturedProductionTextWithoutRefreshingPanels() async throws {
        let (gallery, root) = try gallery()
        defer { try? FileManager.default.removeItem(at: root) }
        let identities = gallery.items.map { ObjectIdentifier($0.renderedVoice) }
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertNil(gallery.item("selection-copy-empty").voice.confirmationText, "Original genuine timer expires")
        XCTAssertEqual(gallery.item("selection-copy-empty").renderedVoice.confirmationText,
            "No text\nReselect", "Separate captured production presentation stays pinned")
        gallery.refreshPinnedStates()
        XCTAssertEqual(gallery.items.map { ObjectIdentifier($0.renderedVoice) }, identities)
        gallery.startClocks()
        let clockModels = gallery.items.map { ObjectIdentifier($0.renderedVoice) }
        let origin = gallery.clockOrigin
        gallery.selectPage(1)
        XCTAssertEqual(gallery.clockGeneration, 1)
        XCTAssertEqual(gallery.clockOrigin, origin)
        XCTAssertEqual(gallery.items.map { ObjectIdentifier($0.renderedVoice) }, clockModels)
        XCTAssertTrue(gallery.items.allSatisfy { $0.heldPresentation == nil })
    }

    private static let axTestFrame = CGRect(x: -100, y: 930, width: 300, height: 50)


}
#endif
