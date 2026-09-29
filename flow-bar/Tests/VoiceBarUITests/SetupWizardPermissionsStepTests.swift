@testable import VoiceBarUI
import XCTest

/// F3 step 1: the three permissions, live. Headless: the step's value model only.
final class SetupWizardPermissionsStepTests: XCTestCase {
    func testRowsAreMicrophoneAccessibilityInputMonitoringWithSettingsLabels() {
        let step = SetupPermissionsStep(snapshot: .allGranted)
        XCTAssertEqual(step.rows.map(\.permission), [.microphone, .accessibility, .inputMonitoring])
        XCTAssertEqual(step.rows.map(\.label), ["Microphone", "Accessibility", "Input Monitoring"])
    }

    func testAGrantedPermissionShowsGrantedAndNoAction() {
        let step = SetupPermissionsStep(snapshot: .allGranted)
        XCTAssertTrue(step.allGranted)
        for row in step.rows {
            XCTAssertEqual(row.status, "Granted", "\(row.permission)")
            XCTAssertNil(row.action, "\(row.permission)")
        }
    }

    func testAMissingPermissionOpensItsOwnSystemSettingsPane() {
        let step = SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: .denied, accessibilityGranted: false, inputMonitoringGranted: false, hotkeyListenerActive: false
        ))
        XCTAssertFalse(step.allGranted)
        XCTAssertEqual(step.rows.map(\.status), ["Missing", "Missing", "Missing"])
        XCTAssertEqual(step.rows.map(\.action), [
            .openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
            .openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            .openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
        ])
        XCTAssertEqual(step.rows.map(\.action?.title), ["Open", "Open", "Open"])
    }

    /// A fresh install has never asked for the microphone, so VoiceBar isn't listed in that pane yet: the row asks.
    func testAMicrophoneNeverAskedForIsRequestedNotOpened() {
        let step = SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: .notRequested, accessibilityGranted: true, inputMonitoringGranted: true,
            hotkeyListenerActive: true
        ))
        XCTAssertEqual(step.rows[0].status, "Not requested")
        XCTAssertEqual(step.rows[0].action, .requestMicrophone)
        XCTAssertEqual(step.rows[0].action?.title, "Allow…")
        XCTAssertFalse(step.allGranted)
    }

    /// The F5 listener starts at launch; permissions granted afterwards need a restart before F5 works.
    func testGrantingAccessibilityAndInputMonitoringAfterLaunchAsksForARestart() {
        let step = SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: .granted, accessibilityGranted: true, inputMonitoringGranted: true, hotkeyListenerActive: false
        ))
        XCTAssertTrue(step.allGranted)
        XCTAssertEqual(
            step.restartNote,
            "F5 is still off. Press Restart listener on the next step to turn it on."
        )
    }

    func testNoRestartNoteWhileAPermissionIsStillMissingOrTheListenerRuns() {
        XCTAssertNil(SetupPermissionsStep(snapshot: .allGranted).restartNote)
        XCTAssertNil(SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: .granted, accessibilityGranted: true, inputMonitoringGranted: false, hotkeyListenerActive: false
        )).restartNote)
    }

    func testTheUnknownSnapshotNeverClaimsGranted() {
        let step = SetupPermissionsStep(snapshot: .unknown)
        XCTAssertFalse(step.allGranted)
        XCTAssertFalse(step.rows.contains { $0.status == "Granted" })
    }
}
