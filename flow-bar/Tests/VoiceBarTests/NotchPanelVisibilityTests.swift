import AppKit
import OffscreenTestSupport
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class NotchPanelVisibilityTests: XCTestCase {
    @MainActor private final class Panel: NSPanel {
        var mask = 3, reorders = 0 // Bits: AppKit visible, active Space, occluded, snoozed.
        override var isVisible: Bool {
            mask & 1 != 0
        }

        override var isOnActiveSpace: Bool {
            mask & 2 != 0
        }

        override var occlusionState: NSWindow.OcclusionState {
            mask & 4 != 0 ? [] : [.visible]
        }

        override func orderFrontRegardless() {
            reorders += 1
            mask = 3
        }

        override func orderFront(_ sender: Any?) {
            reorders += 1
            mask = 3
        }

        override func orderOut(_ sender: Any?) {
            mask &= ~1
        }
    }

    @MainActor func testOrderingGateRejectsBothFrontMethodsWhileHidden() {
        let panel = Panel()
        for regardless in [false, true] {
            for hidden in [false, true] {
                panel.mask = 3
                panel.reorders = 0
                XCTAssertEqual(NotchPanelVisibility.present(panel, isHidden: hidden, regardless: regardless), !hidden)
                XCTAssertEqual(panel.reorders, hidden ? 0 : 1)
                XCTAssertEqual(panel.isVisible, !hidden)
            }
        }
    }

    @MainActor func testSelfHealOnlyForActiveVisibleMismatchAndNeverWhenSnoozed() {
        let panel = Panel()
        for mode in VoiceMode.allCases {
            for mask in 0 ..< 16 {
                panel.mask = mask
                panel.reorders = 0
                let expected = [.recording, .transcribing, .speaking].contains(mode) &&
                    panel
                    .isVisible && (!panel.isOnActiveSpace || !panel.occlusionState.contains(.visible)) && mask & 8 == 0
                var logs: [[String: String]] = []
                NotchPanelVisibility.selfHeal(panel, mode: mode, isHidden: mask & 8 != 0) { logs.append($0) }
                XCTAssertEqual(panel.reorders, expected ? 1 : 0, "\(mode) mask=\(mask)")
                XCTAssertEqual(logs.count, expected ? 1 : 0)
                if expected {
                    XCTAssertEqual(logs.first?["beforePanelWindowNumber"], String(panel.windowNumber))
                    XCTAssertEqual(logs.first?["afterPanelOcclusionVisible"], "true")
                    XCTAssertEqual(logs.first?["afterPanelOnActiveSpace"], "true")
                }
            }
        }
    }

    func testDeferredHandoffNeverOrdersOutInNonIdleModeOrAfterCancellation() {
        for mode in VoiceMode.allCases {
            for cancelled in [false, true] {
                var hides = 0, layouts = 0
                var currentMode = VoiceMode.idle
                currentMode = mode // A new mode arrived while the collapse was deferred.
                NotchPanelVisibility.finishHandoffCollapse(isCancelled: cancelled, mode: { currentMode },
                                                           refreshLayout: { layouts += 1 }, orderOut: { hides += 1 })
                XCTAssertEqual(hides, mode == .idle && !cancelled ? 1 : 0)
                XCTAssertEqual(layouts, hides)
            }
        }
    }

    func testLayoutReentryCannotHideANewRecording() {
        var mode = VoiceMode.idle, hides = 0
        NotchPanelVisibility.finishHandoffCollapse(isCancelled: false, mode: { mode },
                                                   refreshLayout: { mode = .recording }, orderOut: { hides += 1 })
        XCTAssertEqual(hides, 0)
    }

    @MainActor private func productPanel() -> (AppDelegate, FloatingPillPanel) {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.voiceState.sendCommand = { _ in } // No socket, daemon, audio, or hotkey startup.
        app.voiceState.setConnectionStatus(true)
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100)))
        app.configurePanelVisibilityForTesting(panel)
        VLOrderTestWindow(panel)
        return (app, panel)
    }

    @MainActor private func hide(_ app: AppDelegate) throws {
        try XCTUnwrap(app.quickMenuActions().first { $0.title == "Hide for 1 hour" }).perform()
        XCTAssertTrue(app.isSnoozed)
        XCTAssertTrue(app.voiceState.isHidden)
    }

    @MainActor func testProductSnoozeSurvivesIncomingEventClassesAndShowRestoresCurrentState() throws {
        let scenarios: [(String, (VoiceState) -> Void)] = [
            ("speaking", { $0.handleEvent(["type": "state", "state": "speaking", "text": "hidden update"]) }),
            ("preparing", { $0.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                                           "long_read": ["preparing": true, "chunk_start_ms": 0]]) }),
            ("readback", {
                $0.handleEvent(["type": "state", "state": "speaking", "text": "retained words"])
                $0.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            }),
            ("error", { $0.handleEvent(["type": "error", "message": "synthetic error"]) }),
            ("reconnect", { $0.setConnectionStatus(false); $0.setConnectionStatus(true) }),
            ("confirmation", { $0.confirmationText = "Copied" }),
            ("note", { $0.mode = .transcribing; $0.speakSelection() }),
            ("handoff", {
                $0.handleEvent(["type": "state", "state": "speaking", "text": "question"])
                $0.handleEvent(["type": "state", "state": "idle", "source": "playback", "next_state": "recording"])
            }),
        ]
        for (name, event) in scenarios {
            let (app, panel) = productPanel()
            defer { app.unsnoozeNow(); panel.orderOut(nil) }
            try hide(app)
            XCTAssertFalse(panel.isVisible, "snooze: \(name)")
            event(app.voiceState)
            XCTAssertFalse(panel.isVisible, "incoming \(name) must stay ordered out")
            let mode = app.voiceState.mode
            let text = app.voiceState.statusText
            let readback = app.voiceState.isTeleprompterReadback
            app.unsnoozeNow()
            XCTAssertTrue(panel.isVisible, "show: \(name)")
            XCTAssertFalse(app.voiceState.isHidden)
            XCTAssertNil(app.snoozedUntil)
            XCTAssertEqual(app.voiceState.mode, mode == .disconnected ? .idle : mode, name)
            XCTAssertEqual(app.voiceState.statusText, text, name)
            XCTAssertEqual(app.voiceState.isTeleprompterReadback, readback, name)
        }
    }

    @MainActor func testProductSnoozeStaysOrderedOutAcrossDeferredHandoffCollapse() async throws {
        let (app, panel) = productPanel()
        defer { app.unsnoozeNow(); panel.orderOut(nil) }
        try hide(app)
        app.voiceState.handleEvent(["type": "state", "state": "speaking", "text": "question"])
        XCTAssertFalse(panel.isVisible)
        app.voiceState.handleEvent(["type": "state", "state": "idle", "source": "playback", "next_state": "recording"])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(panel.isVisible)
        app.unsnoozeNow()
        XCTAssertTrue(panel.isVisible)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(panel.isVisible, "a stale collapse must not hide the restored panel")
    }

    @MainActor func testProductSnoozeExpiryShowsCurrentSpeech() async throws {
        let (app, panel) = productPanel()
        defer { app.unsnoozeNow(); panel.orderOut(nil) }
        app.configurePanelVisibilityForTesting(panel, snoozeSleep: {
            try await Task.sleep(for: .milliseconds(20))
        })
        try hide(app)
        app.voiceState.handleEvent(["type": "state", "state": "speaking", "text": "current words"])
        XCTAssertFalse(panel.isVisible)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(app.isSnoozed)
        XCTAssertFalse(app.voiceState.isHidden)
        XCTAssertNil(app.voiceState.hiddenUntil)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(app.voiceState.mode, .speaking)
        XCTAssertEqual(app.voiceState.statusText, "current words")
    }

    @MainActor func testShowCancelsPendingHandoffCollapse() async throws {
        let (app, panel) = productPanel()
        defer { app.unsnoozeNow(); panel.orderOut(nil) }
        try hide(app)
        app.voiceState.handleEvent(["type": "state", "state": "speaking", "text": "question"])
        app.voiceState.handleEvent(["type": "state", "state": "idle", "source": "playback", "next_state": "recording"])
        app.unsnoozeNow()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(panel.isVisible, "pending handoff work must not hide Show VoiceBar")
    }

    @MainActor func testEitherSnoozeFlagClosesTheProductOrderingGate() {
        for stateHidden in [false, true] {
            let (app, panel) = productPanel()
            defer { app.unsnoozeNow(); panel.orderOut(nil) }
            if stateHidden { app.voiceState.snooze() }
            else { app.isSnoozed = true }
            panel.orderOut(nil)
            app.voiceState.handleEvent(["type": "state", "state": "speaking", "text": "hidden"])
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testProductPillHasNoUngatedFrontOrderingCalls() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("pill.orderFront"))
        XCTAssertFalse(source.contains("panel?.orderFront"))
        XCTAssertFalse(source.contains("panel.orderFront"))
        XCTAssertTrue(source.contains("NotchPanelVisibility.present(panel, isHidden: isSnoozed || voiceState.isHidden"))
    }

    @MainActor private final class SetupFixture {
        let app: AppDelegate
        let wizard: SetupWizardWindowController
        let store: SetupWizardCompletionStore
        let defaults: UserDefaults
        let suite = "HIDE1-setup-\(UUID().uuidString)"
        var readiness = SetupLaunchReadiness(permissionsGranted: false, listenerActive: false)
        var presentations = 0
        var onPresentation: (() -> Void)?

        init(app: AppDelegate) throws {
            self.app = app
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = SetupWizardCompletionStore(defaults: defaults)
            wizard = SetupWizardWindowController(defaults: defaults, makeDependencies: { SetupWizardDependencies() })
            app.configureSetupWizardPresentationForTesting { [weak self] in
                guard let self else { return }
                presentations += 1
                wizard.show() // Real controller, synthetic dependencies, shared offscreen policy.
                onPresentation?()
            }
        }

        func detectionFinished() {
            app.completeFirstRunSetupDetection { [weak self] in
                guard let self else { return false }
                return SetupWizardLaunchPolicy.resolve(store: store, hasPriorUse: false, readiness: readiness)
            }
        }

        func close() {
            wizard.windowForTesting?.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor func testAutomaticSetupCallbackAfterSnoozeWaitsForShowAndPresentsOnce() throws {
        let (app, panel) = productPanel()
        let setup = try SetupFixture(app: app)
        defer { app.unsnoozeNow(); setup.close(); panel.orderOut(nil) }
        try hide(app)
        setup.detectionFinished() // The launch background check completes after Hide.
        XCTAssertEqual(setup.presentations, 0)
        XCTAssertNil(setup.wizard.windowForTesting)
        app.commandRouter.handleShowVoiceBar()
        XCTAssertEqual(setup.presentations, 1)
        XCTAssertEqual(setup.wizard.windowForTesting?.isVisible, true)
        app.unsnoozeNow()
        XCTAssertEqual(setup.presentations, 1, "automatic setup must be consumed once")
    }

    @MainActor func testAutomaticSetupRechecksWhetherItIsNeededAfterSnooze() throws {
        for completed in [false, true] {
            let (app, panel) = productPanel()
            let setup = try SetupFixture(app: app)
            defer { app.unsnoozeNow(); setup.close(); panel.orderOut(nil) }
            try hide(app)
            setup.detectionFinished()
            XCTAssertEqual(setup.presentations, 0)
            if completed { setup.store.markCompleted() }
            else { setup.readiness = SetupLaunchReadiness(permissionsGranted: true, listenerActive: true) }
            app.unsnoozeNow()
            XCTAssertEqual(setup.presentations, 0, "completed or ready setup must not pop up on Show")
            XCTAssertTrue(setup.store.isCompleted)
        }
    }

    @MainActor func testAutomaticSetupPresentsOnSnoozeExpiry() async throws {
        let (app, panel) = productPanel()
        let setup = try SetupFixture(app: app)
        defer { app.unsnoozeNow(); setup.close(); panel.orderOut(nil) }
        let presented = expectation(description: "automatic setup presented after snooze expiry")
        setup.onPresentation = { presented.fulfill() }
        // Release the injected timer immediately, then await the actual presentation.
        app.configurePanelVisibilityForTesting(panel, snoozeSleep: {})
        try hide(app)
        setup.detectionFinished()
        XCTAssertEqual(setup.presentations, 0)
        await fulfillment(of: [presented], timeout: 5)
        XCTAssertFalse(app.isSnoozed)
        XCTAssertEqual(setup.presentations, 1)
        XCTAssertEqual(setup.wizard.windowForTesting?.isVisible, true)
        app.unsnoozeNow()
        XCTAssertEqual(setup.presentations, 1)
    }

    @MainActor func testExplicitRunSetupIsExemptAndConsumesAutomaticPresentation() throws {
        for detectionFirst in [false, true] {
            let (app, panel) = productPanel()
            let setup = try SetupFixture(app: app)
            defer { app.unsnoozeNow(); setup.close(); panel.orderOut(nil) }
            try hide(app)
            if detectionFirst { setup.detectionFinished() }
            app.openSetupWizard() // The same explicit action used by Settings and the menu.
            if !detectionFirst { setup.detectionFinished() }
            XCTAssertTrue(app.isSnoozed)
            XCTAssertEqual(setup.presentations, 1)
            XCTAssertEqual(setup.wizard.windowForTesting?.isVisible, true)
            app.unsnoozeNow()
            XCTAssertEqual(setup.presentations, 1, "Show must not front an explicitly opened wizard again")
        }
    }

    @MainActor func testAutomaticSetupRespectsEitherHiddenFlag() throws {
        for stateHidden in [false, true] {
            let (app, panel) = productPanel()
            let setup = try SetupFixture(app: app)
            defer { app.unsnoozeNow(); setup.close(); panel.orderOut(nil) }
            if stateHidden { app.voiceState.snooze() }
            else { app.isSnoozed = true }
            setup.detectionFinished()
            XCTAssertEqual(setup.presentations, 0)
            app.unsnoozeNow()
            XCTAssertEqual(setup.presentations, 1)
        }
    }

    @MainActor func testAutomaticSetupStillPresentsImmediatelyWhenShown() throws {
        let (app, panel) = productPanel()
        let setup = try SetupFixture(app: app)
        defer { setup.close(); panel.orderOut(nil) }
        setup.detectionFinished()
        XCTAssertEqual(setup.presentations, 1)
        XCTAssertEqual(setup.wizard.windowForTesting?.isVisible, true)
        setup.detectionFinished()
        app.unsnoozeNow()
        XCTAssertEqual(setup.presentations, 1)
    }

}
