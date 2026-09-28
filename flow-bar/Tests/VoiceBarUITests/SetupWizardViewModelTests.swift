@testable import VoiceBarUI
import XCTest

/// F3 shell: what the wizard window shows around each step, read from value models (no window, no events).
final class SetupWizardViewModelTests: XCTestCase {
    func testWelcomeOffersGetStartedAndSkipSetupButNoBackOrSkipStep() {
        let footer = SetupWizardFooter(model: SetupWizardModel(step: .welcome))
        XCTAssertEqual(footer.primaryTitle, "Get started")
        XCTAssertTrue(footer.showsSkipSetup)
        XCTAssertFalse(footer.showsBack)
        XCTAssertFalse(footer.showsSkipStep)
    }

    func testSetupStepsOfferBackSkipThisStepAndSkipSetup() {
        for step in SetupWizardStep.setupSteps {
            let footer = SetupWizardFooter(model: SetupWizardModel(step: step))
            XCTAssertTrue(footer.showsSkipSetup, "\(step)")
            XCTAssertTrue(footer.showsBack, "\(step)")
            XCTAssertTrue(footer.showsSkipStep, "\(step)")
            XCTAssertEqual(footer.primaryTitle, "Continue", "\(step)")
        }
    }

    func testDoneOffersOnlyItsPrimaryButton() {
        let footer = SetupWizardFooter(model: SetupWizardModel(step: .done))
        XCTAssertEqual(footer.primaryTitle, "Start using VoiceBar")
        XCTAssertFalse(footer.showsSkipSetup)
        XCTAssertFalse(footer.showsBack)
        XCTAssertFalse(footer.showsSkipStep)
    }

    func testProgressFillsUpToTheCurrentSetupStep() {
        XCTAssertEqual(SetupWizardFooter(model: SetupWizardModel(step: .welcome)).completedSegments, 0)
        XCTAssertEqual(SetupWizardFooter(model: SetupWizardModel(step: .permissions)).completedSegments, 1)
        XCTAssertEqual(SetupWizardFooter(model: SetupWizardModel(step: .tryIt)).completedSegments, 4)
        XCTAssertEqual(SetupWizardFooter(model: SetupWizardModel(step: .done)).completedSegments, 4)
    }

    func testDoneSaysEverythingIsSetWhenNothingWasSkipped() {
        let summary = SetupWizardDoneSummary(skippedSteps: [])
        XCTAssertTrue(summary.isComplete)
        XCTAssertNil(summary.unfinishedLine)
    }

    func testDoneNamesEachSkippedStepAndWhereToFinishIt() {
        var model = SetupWizardModel(step: .permissions)
        model.skipStep()
        model.continueToNextStep()
        model.skipStep()
        let summary = SetupWizardDoneSummary(skippedSteps: model.skippedSteps)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.skippedNames, ["Permissions", "Microphone"])
        XCTAssertEqual(
            summary.unfinishedLine,
            "Skipped: Permissions, Microphone. Finish them in Settings › General, or run setup again from the menu."
        )
    }
}
