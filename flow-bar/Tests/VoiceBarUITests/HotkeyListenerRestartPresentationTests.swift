@testable import VoiceBarUI
import XCTest

/// "Restart F5 listener" in Settings › General › Shortcut and the wizard's F5 key step: shown only while the
/// listener is off, and the result reported in place. Headless: value models only.
final class HotkeyListenerRestartPresentationTests: XCTestCase {
    private func settings(hotkeyEnabled: Bool) -> SettingsView {
        SettingsView(
            hotkeyEnabled: hotkeyEnabled,
            missingPermissions: hotkeyEnabled ? [] : [.accessibility],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 }
        )
    }

    func testSettingsShowsRestartOnlyWhileTheListenerIsOff() {
        XCTAssertTrue(settings(hotkeyEnabled: false).showsHotkeyListenerRestart)
        XCTAssertFalse(settings(hotkeyEnabled: true).showsHotkeyListenerRestart)
    }

    func testTheWizardF5StepShowsRestartOnlyWhileTheListenerIsOff() {
        XCTAssertTrue(SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: false, helperInstalled: true))
            .showsListenerRestart)
        XCTAssertFalse(SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: true, helperInstalled: true))
            .showsListenerRestart)
    }

    func testAStartedListenerSaysSo() {
        XCTAssertEqual(
            HotkeyListenerRestartLine(outcome: .started),
            HotkeyListenerRestartLine(text: "F5 listener is on.", succeeded: true)
        )
        XCTAssertEqual(
            HotkeyListenerRestartLine(outcome: .alreadyRunning),
            HotkeyListenerRestartLine(text: "F5 listener is already on.", succeeded: true)
        )
    }

    func testARefusalWhileRecordingSaysWhy() {
        XCTAssertEqual(
            HotkeyListenerRestartLine(outcome: .refusedWhileRecording),
            HotkeyListenerRestartLine(
                text: "Not restarted: a recording is in progress. Try again when it ends.",
                succeeded: false
            )
        )
    }

    func testAFailureNamesWhatIsStillMissing() {
        XCTAssertEqual(
            HotkeyListenerRestartLine(outcome: .failed(missing: [.accessibility, .inputMonitoring])),
            HotkeyListenerRestartLine(
                text: "Still off: Accessibility and Input Monitoring are missing. If you just allowed access, quit and reopen VoiceBar.",
                succeeded: false
            )
        )
        XCTAssertEqual(
            HotkeyListenerRestartLine(outcome: .failed(missing: [])),
            HotkeyListenerRestartLine(
                text: "Still off: the F5 listener couldn't start. If you just allowed access, quit and reopen VoiceBar.",
                succeeded: false
            )
        )
    }

    func testTheWizardStepCarriesTheRestartResult() {
        let step = SetupF5KeyStep(
            status: SetupF5KeyStatus(listenerActive: true, helperInstalled: true),
            listenerRestart: .started
        )
        XCTAssertEqual(step.listenerRestartLine, HotkeyListenerRestartLine(text: "F5 listener is on.", succeeded: true))
        XCTAssertNil(SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: false, helperInstalled: true))
            .listenerRestartLine)
    }
}
