import AppKit
import AVFoundation
import SwiftUI
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// F3 integration: one wizard window, never modal, and closing it counts as Skip setup.
final class SetupWizardWindowControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SetupWizardWindowControllerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    @MainActor
    func testShowOpensOneNonModalWizardWindowAndReusesIt() throws {
        let wizard = SetupWizardWindowController(defaults: defaults, makeDependencies: { SetupWizardDependencies() })
        wizard.show()
        defer { wizard.windowForTesting?.close() }
        let window = try XCTUnwrap(wizard.windowForTesting)
        XCTAssertEqual(window.title, "Set up VoiceBar")
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(NSApplication.shared.modalWindow, "the wizard never blocks the app")
        XCTAssertTrue(window.contentViewController is NSHostingController<SetupWizardView>)

        wizard.show()
        XCTAssertTrue(wizard.windowForTesting === window, "a second open fronts the same window")
    }

    @MainActor
    func testClosingTheWindowMarksSetupCompletedAndReleasesIt() throws {
        let wizard = SetupWizardWindowController(defaults: defaults, makeDependencies: { SetupWizardDependencies() })
        wizard.show()
        try XCTUnwrap(wizard.windowForTesting).close()
        XCTAssertNil(wizard.windowForTesting)
        XCTAssertTrue(SetupWizardCompletionStore(defaults: defaults).isCompleted)
    }

    @MainActor
    func testSkipSetupClosesTheWindow() throws {
        let wizard = SetupWizardWindowController(defaults: defaults, makeDependencies: { SetupWizardDependencies() })
        wizard.show()
        let window = try XCTUnwrap(wizard.windowForTesting)
        try XCTUnwrap(wizard.controllerForTesting).skipSetup()
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(wizard.windowForTesting)
        XCTAssertTrue(SetupWizardCompletionStore(defaults: defaults).isCompleted)
    }

    func testMicrophoneAuthorizationMapsToTheStepsThreeStates() {
        XCTAssertEqual(AppDelegate.setupMicrophoneAuthorization(.authorized), .granted)
        XCTAssertEqual(AppDelegate.setupMicrophoneAuthorization(.notDetermined), .notRequested)
        XCTAssertEqual(AppDelegate.setupMicrophoneAuthorization(.denied), .denied)
        XCTAssertEqual(AppDelegate.setupMicrophoneAuthorization(.restricted), .denied)
    }

    /// The wizard reuses the app's existing actions (brief: it never reimplements them).
    func testTheAppWiresTheWizardToItsExistingActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"),
                             encoding: .utf8)
        for wiring in [
            "self?.runRelaySetupAsync(completion: completion)",
            "self?.openMicrophonePrioritySettings()",
            "self?.defaultMicrophoneName()",
            "HotkeyManager.currentPermissionStatus()",
            "voiceState.lastDictationCardEntry",
            "voiceState.latestDictationInsertionStatus",
            "onRunSetup: { [weak self] in self?.openSetupWizard() }",
            "onRunSetup: { appDelegate.openSetupWizardFromMenuBar(popover: AppDelegate.menuBarPopoverWindow()) }",
        ] {
            XCTAssertTrue(app.contains(wiring), wiring)
        }
        let launch = try XCTUnwrap(app.range(of: "setupHotkey()\n        }\n        configureWakeRecovery()"))
        XCTAssertTrue(
            app[launch.upperBound...].hasPrefix("\n        scheduleFirstRunSetupIfNeeded()"),
            "first-run setup is decided right after the F5 listener starts, so the listener state is known"
        )
    }
}
