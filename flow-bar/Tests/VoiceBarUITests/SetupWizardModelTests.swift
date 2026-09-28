@testable import VoiceBarUI
import XCTest

/// F3: the first-run setup wizard's state machine. Headless: it drives the model and the controller, never a window.
final class SetupWizardModelTests: XCTestCase {
    func testStepsRunWelcomePermissionsF5MicrophoneTryItDone() {
        XCTAssertEqual(SetupWizardStep.allCases, [.welcome, .permissions, .f5Key, .microphone, .tryIt, .done])
        XCTAssertEqual(SetupWizardModel().step, .welcome)
    }

    func testContinueWalksEveryStepAndStopsAtDone() {
        var model = SetupWizardModel()
        var visited = [model.step]
        for _ in 0 ..< 8 {
            model.continueToNextStep()
            visited.append(model.step)
        }
        XCTAssertEqual(Array(visited.prefix(6)), SetupWizardStep.allCases)
        XCTAssertTrue(visited.dropFirst(5).allSatisfy { $0 == .done })
    }

    func testBackStepsBackAndIsUnavailableOnWelcomeAndDone() {
        var model = SetupWizardModel(step: .microphone)
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertEqual(model.step, .f5Key)

        var welcome = SetupWizardModel()
        XCTAssertFalse(welcome.canGoBack)
        welcome.goBack()
        XCTAssertEqual(welcome.step, .welcome)

        var done = SetupWizardModel(step: .done)
        XCTAssertFalse(done.canGoBack)
        done.goBack()
        XCTAssertEqual(done.step, .done)
    }

    func testSkippingAStepAdvancesAndRemembersItUntilItIsCompleted() {
        var model = SetupWizardModel(step: .permissions)
        model.skipStep()
        XCTAssertEqual(model.step, .f5Key)
        model.skipStep()
        XCTAssertEqual(model.step, .microphone)
        XCTAssertEqual(model.skippedSteps, [.permissions, .f5Key])

        model.goBack()
        model.continueToNextStep()
        XCTAssertEqual(model.skippedSteps, [.permissions], "Continue on a skipped step clears it")
    }

    func testEveryStepButDoneCanBeSkipped() {
        for step in SetupWizardStep.allCases {
            XCTAssertEqual(SetupWizardModel(step: step).canSkipStep, step.isSetupStep, "\(step)")
        }
        XCTAssertFalse(SetupWizardStep.welcome.isSetupStep)
        XCTAssertFalse(SetupWizardStep.done.isSetupStep)
    }

    func testProgressCountsOnlyTheFourSetupSteps() {
        XCTAssertNil(SetupWizardStep.welcome.progressLabel)
        XCTAssertEqual(SetupWizardStep.permissions.progressLabel, "Step 1 of 4")
        XCTAssertEqual(SetupWizardStep.f5Key.progressLabel, "Step 2 of 4")
        XCTAssertEqual(SetupWizardStep.microphone.progressLabel, "Step 3 of 4")
        XCTAssertEqual(SetupWizardStep.tryIt.progressLabel, "Step 4 of 4")
        XCTAssertNil(SetupWizardStep.done.progressLabel)
    }

    func testPrimaryButtonNamesWhatHappensNext() {
        XCTAssertEqual(SetupWizardStep.welcome.primaryTitle, "Get started")
        XCTAssertEqual(SetupWizardStep.permissions.primaryTitle, "Continue")
        XCTAssertEqual(SetupWizardStep.tryIt.primaryTitle, "Continue")
        XCTAssertEqual(SetupWizardStep.done.primaryTitle, "Start using VoiceBar")
    }

    func testEveryStepHasATitle() {
        for step in SetupWizardStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step)")
        }
    }
}

final class SetupWizardControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SetupWizardControllerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testFreshInstallIsNotCompletedAndStartsAtWelcome() {
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertFalse(store.isCompleted)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(SetupWizardController(store: store).model.step, .welcome)
    }

    func testQuittingMidSetupResumesAtTheSameStep() {
        let first = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults))
        first.continueToNextStep()
        first.continueToNextStep()
        XCTAssertEqual(first.model.step, .f5Key)

        // e.g. macOS asked to relaunch VoiceBar after Input Monitoring was granted.
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertFalse(store.isCompleted)
        XCTAssertEqual(SetupWizardController(store: store).model.step, .f5Key)
    }

    /// Round 1 (Macroscope / CodeRabbit): a skipped step must still be named on Done after a relaunch.
    func testSkippedStepsSurviveARelaunchAndCompletionClearsThem() {
        let first = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults))
        first.continueToNextStep() // Welcome → Permissions
        first.skipStep() // Permissions skipped → F5 key
        XCTAssertEqual(first.model.skippedSteps, [.permissions])

        let store = SetupWizardCompletionStore(defaults: defaults)
        let resumed = SetupWizardController(store: store)
        XCTAssertEqual(resumed.model.step, .f5Key)
        XCTAssertEqual(resumed.model.skippedSteps, [.permissions])
        for _ in 0 ..< 3 {
            resumed.continueToNextStep()
        }
        XCTAssertEqual(resumed.model.step, .done)
        XCTAssertEqual(SetupWizardDoneSummary(skippedSteps: resumed.model.skippedSteps).skippedNames, ["Permissions"])

        resumed.continueToNextStep() // Finish
        XCTAssertTrue(store.isCompleted)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(store.resumeSkippedSteps, [])
        XCTAssertNil(defaults.object(forKey: SetupWizardCompletionStore.resumeSkippedStepsKey))
    }

    /// Round 1: reaching Done is not finishing, so a quit there resumes at Done, not Welcome.
    func testAQuitOnDoneResumesAtDoneWithItsSkippedSteps() {
        let first = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults))
        first.continueToNextStep()
        first.continueToNextStep()
        first.skipStep() // F5 key skipped
        first.continueToNextStep()
        first.continueToNextStep()
        XCTAssertEqual(first.model.step, .done)

        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertFalse(store.isCompleted)
        let resumed = SetupWizardController(store: store)
        XCTAssertEqual(resumed.model.step, .done)
        XCTAssertEqual(resumed.model.skippedSteps, [.f5Key])
    }

    func testCompletingFromSkipSetupOrWindowCloseClearsTheSkippedSteps() {
        let first = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults))
        first.continueToNextStep()
        first.skipStep()
        first.windowDidClose()
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(store.resumeSkippedSteps, [])
    }

    func testUnreadableSkippedEntriesAreDropped() {
        defaults.set(SetupWizardStep.microphone.rawValue, forKey: SetupWizardCompletionStore.resumeStepKey)
        defaults.set(["f5Key", "not-a-step", "welcome"], forKey: SetupWizardCompletionStore.resumeSkippedStepsKey)
        let controller = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults))
        XCTAssertEqual(controller.model.step, .microphone)
        XCTAssertEqual(controller.model.skippedSteps, [.f5Key], "only setup steps before the resume step")
    }

    func testFinishingMarksSetupCompletedAndClosesOnce() {
        var closes = 0
        let store = SetupWizardCompletionStore(defaults: defaults)
        let controller = SetupWizardController(store: store, onClose: { closes += 1 })
        for _ in 0 ..< 5 {
            controller.continueToNextStep()
        }
        XCTAssertEqual(controller.model.step, .done)
        XCTAssertFalse(store.isCompleted, "reaching Done is not finishing")

        controller.continueToNextStep()
        XCTAssertTrue(store.isCompleted)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(closes, 1)

        controller.windowDidClose()
        XCTAssertEqual(closes, 1, "the window closing after Finish is not a second close")
    }

    func testSkipSetupFromAnyStepMarksCompletedWithoutBlocking() throws {
        for step in SetupWizardStep.allCases where step != .done {
            let suite = "SetupWizardSkip-\(UUID().uuidString)"
            let stepDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { stepDefaults.removePersistentDomain(forName: suite) }
            var closes = 0
            let store = SetupWizardCompletionStore(defaults: stepDefaults)
            let controller = SetupWizardController(
                store: store,
                model: SetupWizardModel(step: step),
                onClose: { closes += 1 }
            )
            controller.skipSetup()
            XCTAssertTrue(store.isCompleted, "\(step)")
            XCTAssertNil(store.resumeStep, "\(step)")
            XCTAssertEqual(closes, 1, "\(step)")
        }
    }

    func testClosingTheWindowCountsAsSkippingSetup() {
        var closes = 0
        let store = SetupWizardCompletionStore(defaults: defaults)
        let controller = SetupWizardController(store: store, onClose: { closes += 1 })
        controller.continueToNextStep()
        controller.windowDidClose()
        XCTAssertTrue(store.isCompleted)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(closes, 0, "the window is already closing; the controller does not close it again")
    }

    func testRunSetupAgainStartsAtWelcomeAndKeepsTheCompletedFlag() {
        let store = SetupWizardCompletionStore(defaults: defaults)
        store.markCompleted()
        let controller = SetupWizardController(store: store)
        XCTAssertEqual(controller.model.step, .welcome)
        controller.continueToNextStep()
        XCTAssertTrue(store.isCompleted)
        XCTAssertNil(store.resumeStep, "a re-run never resumes: it is not first-run setup")
    }

    func testAnUnreadableResumeStepFallsBackToWelcome() {
        defaults.set("not-a-step", forKey: SetupWizardCompletionStore.resumeStepKey)
        let store = SetupWizardCompletionStore(defaults: defaults)
        XCTAssertNil(store.resumeStep)
        XCTAssertEqual(SetupWizardController(store: store).model.step, .welcome)
    }
}
