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

/// #208 round 1: the helper run belongs to the wizard, not to the F5 step's view, so leaving the step can't lose it.
final class SetupWizardRelayRunLifecycleTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let helperMissing = SetupF5KeyStatus(listenerActive: true, helperInstalled: false)

    override func setUpWithError() throws {
        suiteName = "SetupWizardRelayRunLifecycleTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func controllerOnF5Key() -> SetupWizardController {
        SetupWizardController(
            store: SetupWizardCompletionStore(defaults: defaults),
            model: SetupWizardModel(step: .f5Key)
        )
    }

    func testAPendingSetupIsStillPendingAfterLeavingTheStepAndComingBack() {
        let controller = controllerOnF5Key()
        var pendingCompletions: [(SettingsRelaySetupResult) -> Void] = []
        controller.startRelaySetup(.setUp) { pendingCompletions.append($0) }

        controller.continueToNextStep() // → Microphone
        controller.goBack() // → F5 key
        controller.goBack(to: .permissions) // Allow access…
        controller.continueToNextStep() // → F5 key again
        XCTAssertEqual(controller.model.step, .f5Key)

        let step = SetupF5KeyStep(status: helperMissing, run: controller.relayRun)
        XCTAssertEqual(controller.relayRun, SetupRelayRun(action: .setUp, result: nil))
        XCTAssertFalse(step.helperButtonEnabled, "Set up stays disabled while the first run is pending")
        XCTAssertEqual(step.resultLine, SetupF5KeyResultLine(text: "Setting up…", tone: .running))
        XCTAssertEqual(pendingCompletions.count, 1)
    }

    func testAResultThatArrivesOnAnotherStepIsShownOnReturn() {
        let controller = controllerOnF5Key()
        var completion: ((SettingsRelaySetupResult) -> Void)?
        controller.startRelaySetup(.reinstall) { completion = $0 }
        controller.continueToNextStep() // user moved on to Microphone
        let ready = SettingsRelaySetupResult(outcome: .ready, finishedAt: Date(timeIntervalSince1970: 1_800_000_000))
        completion?(ready)

        controller.goBack()
        let step = SetupF5KeyStep(status: SetupF5KeyStatus(listenerActive: true, helperInstalled: true),
                                  run: controller.relayRun)
        XCTAssertEqual(step.resultLine?.text, SettingsRelaySetupFeedback.line(for: ready, action: .reinstall))
        XCTAssertEqual(step.resultLine?.tone, .success)
        XCTAssertTrue(step.helperButtonEnabled)
    }

    func testASecondStartWhilePendingIsIgnoredAndAFinishedRunCanBeRepeated() {
        let controller = controllerOnF5Key()
        var starts = 0
        var completion: ((SettingsRelaySetupResult) -> Void)?
        controller.startRelaySetup(.setUp) { starts += 1
            completion = $0
        }
        controller.startRelaySetup(.setUp) { starts += 1
            completion = $0
        }
        XCTAssertEqual(starts, 1, "the wizard never asks the app for a second run while one is pending")

        completion?(SettingsRelaySetupResult(outcome: .failed(reason: "installer exited 1"), finishedAt: Date()))
        controller.startRelaySetup(.setUp) { starts += 1
            completion = $0
        }
        XCTAssertEqual(starts, 2, "after a result, Set up can run again")
        XCTAssertEqual(controller.relayRun, SetupRelayRun(action: .setUp, result: nil))
    }
}
