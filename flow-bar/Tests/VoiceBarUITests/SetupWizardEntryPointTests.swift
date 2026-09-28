@testable import VoiceBarUI
import XCTest

/// F3 entry points: when the wizard opens by itself, and the two ways to open it again.
final class SetupWizardLaunchPolicyTests: XCTestCase {
    private let allReady = SetupLaunchReadiness(permissionsGranted: true, listenerActive: true, helperInstalled: true)

    func testAFreshInstallWithSomethingToSetUpShowsTheWizard() {
        for readiness in [
            SetupLaunchReadiness(permissionsGranted: false, listenerActive: false, helperInstalled: false),
            SetupLaunchReadiness(permissionsGranted: true, listenerActive: false, helperInstalled: true),
            SetupLaunchReadiness(permissionsGranted: true, listenerActive: true, helperInstalled: false),
        ] {
            XCTAssertEqual(
                SetupWizardLaunchPolicy.decide(isCompleted: false, hasResumeStep: false, readiness: readiness),
                .show,
                "\(readiness)"
            )
        }
    }

    /// An install that already works (an upgrade on a set-up Mac) is marked completed silently.
    func testAnInstallThatAlreadyWorksIsMarkedCompletedWithoutShowing() {
        XCTAssertEqual(
            SetupWizardLaunchPolicy.decide(isCompleted: false, hasResumeStep: false, readiness: allReady),
            .markCompleted
        )
    }

    func testAnUnfinishedFirstRunResumesEvenWhenEverythingIsReadyNow() {
        XCTAssertEqual(
            SetupWizardLaunchPolicy.decide(isCompleted: false, hasResumeStep: true, readiness: allReady),
            .show,
            "e.g. relaunched after Input Monitoring: the user is mid-setup and hasn't tried a dictation yet"
        )
    }

    func testACompletedSetupNeverOpensByItself() {
        XCTAssertEqual(
            SetupWizardLaunchPolicy.decide(
                isCompleted: true,
                hasResumeStep: true,
                readiness: SetupLaunchReadiness(
                    permissionsGranted: false,
                    listenerActive: false,
                    helperInstalled: false
                )
            ),
            .none
        )
    }
}

final class SetupWizardEntryPointContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testSettingsGeneralOffersRunSetupAgain() throws {
        let settings = try source("Sources/VoiceBarUI/SettingsView.swift")
        XCTAssertTrue(settings.contains("public let onRunSetup: () -> Void"))
        XCTAssertTrue(settings.contains("Button(\"Run setup again\") {\n                    onRunSetup()"))
    }

    func testTheMenuBarPopoverOffersRunSetup() throws {
        let popover = try source("Sources/VoiceBarUI/MenuBarPopoverView.swift")
        XCTAssertTrue(popover.contains("public let onRunSetup: () -> Void"))
        XCTAssertTrue(popover.contains("Button(\"Run setup…\", action: onRunSetup)"))
    }
}
