@testable import VoiceBarUI
import XCTest

/// F3 step 3: the microphone-priority default, read-only, with "Change…" to Settings (Etan's D2, #182).
final class SetupWizardMicrophoneStepTests: XCTestCase {
    func testShowsTheDefaultExactlyLikeTheMenuAndPopover() {
        let step = SetupMicrophoneStep(defaultName: "Studio USB Mic")
        XCTAssertEqual(step.defaultTitle, MicrophoneDefaultPresentation.title("Studio USB Mic"))
        XCTAssertEqual(step.defaultTitle, "Default: Studio USB Mic")
        XCTAssertEqual(step.accessibilityLabel, MicrophoneDefaultPresentation.accessibilityLabel("Studio USB Mic"))
        XCTAssertEqual(step.changeTitle, MicrophoneDefaultPresentation.changeTitle)
        XCTAssertEqual(step.changeAccessibilityLabel, MicrophoneDefaultPresentation.changeAccessibilityLabel)
        XCTAssertTrue(step.isReady)
        XCTAssertNil(step.problem)
    }

    func testNoMicrophoneSaysSoAndStillOffersChange() {
        let step = SetupMicrophoneStep(defaultName: nil)
        XCTAssertEqual(step.defaultTitle, "Default: Unavailable")
        XCTAssertFalse(step.isReady)
        XCTAssertEqual(step.problem, "No microphone found. Connect one, then pick it with Change…")
        XCTAssertEqual(step.changeTitle, "Change…")
    }

    func testABlankNameCountsAsNoMicrophone() {
        XCTAssertFalse(SetupMicrophoneStep(defaultName: "  ").isReady)
        XCTAssertEqual(SetupMicrophoneStep(defaultName: "  ").defaultTitle, "Default: Unavailable")
    }
}
