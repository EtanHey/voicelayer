@testable import VoiceBarUI
import XCTest

/// F3 step 2: the F5 listener and the F5 key helper (Settings › Advanced's Set up / Reinstall and its #193 result).
final class SetupWizardF5KeyStepTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadyWhenTheListenerRunsAndTheHelperIsInstalled() {
        let step = SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: true, helperInstalled: true))
        XCTAssertTrue(step.isReady)
        XCTAssertEqual(step.listenerStatus, "On")
        XCTAssertEqual(step.helperStatus, "Installed")
        XCTAssertEqual(step.helperButtonTitle, "Reinstall")
        XCTAssertNil(step.listenerProblem)
    }

    func testAMissingHelperOffersSetUpLikeSettings() {
        let step = SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: true, helperInstalled: false))
        XCTAssertFalse(step.isReady)
        XCTAssertEqual(step.helperStatus, "Not installed")
        XCTAssertEqual(step.helperButtonTitle, "Set up")
        XCTAssertEqual(step.helperAction, .setUp)
        XCTAssertTrue(step.helperButtonEnabled)
    }

    /// The listener is off when Accessibility or Input Monitoring is missing at launch: that is step 1's job.
    func testAnOffListenerPointsBackToAllowAccess() {
        let step = SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: false, helperInstalled: true))
        XCTAssertFalse(step.isReady)
        XCTAssertEqual(step.listenerStatus, "Off")
        XCTAssertEqual(step.listenerProblem, "F5 needs Accessibility and Input Monitoring, then a restart of VoiceBar.")
        XCTAssertEqual(step.listenerFixStep, .permissions)
    }

    func testWhileSetupRunsTheButtonIsDisabledAndSaysSo() {
        let step = SetupF5KeyStep(
            status: SetupF5KeyStatus(listenerActive: true, helperInstalled: false),
            run: SetupRelayRun(action: .setUp, result: nil)
        )
        XCTAssertFalse(step.helperButtonEnabled)
        XCTAssertEqual(step.resultLine, SetupF5KeyResultLine(text: "Setting up…", tone: .running))
    }

    func testAFinishedRunShowsSettingsOwnResultLine() {
        let ready = SettingsRelaySetupResult(outcome: .ready, finishedAt: checkedAt)
        let step = SetupF5KeyStep(
            status: SetupF5KeyStatus(listenerActive: true, helperInstalled: true),
            run: SetupRelayRun(action: .setUp, result: ready)
        )
        XCTAssertEqual(step.resultLine?.text, SettingsRelaySetupFeedback.line(for: ready, action: .setUp))
        XCTAssertEqual(step.resultLine?.tone, .success)
        XCTAssertTrue(step.helperButtonEnabled)

        let failed = SettingsRelaySetupResult(outcome: .failed(reason: "installer exited 1"), finishedAt: checkedAt)
        let failedStep = SetupF5KeyStep(
            status: SetupF5KeyStatus(listenerActive: true, helperInstalled: false),
            run: SetupRelayRun(action: .reinstall, result: failed)
        )
        XCTAssertEqual(failedStep.resultLine?.text, SettingsRelaySetupFeedback.line(for: failed, action: .reinstall))
        XCTAssertEqual(failedStep.resultLine?.tone, .failure)
    }

    func testTheWizardCanJumpBackToAnEarlierStepButNotForward() {
        var model = SetupWizardModel(step: .f5Key)
        model.goBack(to: .microphone)
        XCTAssertEqual(model.step, .f5Key, "never forward")
        model.goBack(to: .permissions)
        XCTAssertEqual(model.step, .permissions)

        var done = SetupWizardModel(step: .done)
        done.goBack(to: .permissions)
        XCTAssertEqual(done.step, .done, "Done has no way back")
    }
}
