@testable import VoiceBarUI
import XCTest

/// F3 step 4: a real dictation, observed through the app's last-dictation state. Headless: value model only.
final class SetupWizardTryItStepTests: XCTestCase {
    private let ready = SetupReadiness(
        permissions: .allGranted,
        f5Key: SetupF5KeyStatus(listenerActive: true, helperInstalled: true),
        microphoneName: "Studio USB Mic"
    )
    private let earlier = RecentTranscriptionEntry(
        text: "an older dictation",
        createdAt: Date(timeIntervalSince1970: 100)
    )
    private let fresh = RecentTranscriptionEntry(
        text: "Testing one two three.",
        createdAt: Date(timeIntervalSince1970: 200)
    )

    private func step(
        baseline: RecentTranscriptionEntry? = nil,
        entry: RecentTranscriptionEntry? = nil,
        insertion: DictationInsertionStatus = .unverified,
        activity: SetupTryItActivity = .idle,
        readiness: SetupReadiness? = nil
    ) -> SetupTryItStep {
        SetupTryItStep(
            baseline: baseline,
            observation: SetupTryItObservation(entry: entry, insertion: insertion, activity: activity),
            readiness: readiness ?? ready
        )
    }

    func testWaitsUntilADictationArrivesAfterTheStepOpened() {
        XCTAssertEqual(step().phase, .waiting)
        XCTAssertEqual(step(baseline: earlier, entry: earlier).phase, .waiting, "an older dictation doesn't count")
        XCTAssertFalse(step(baseline: earlier, entry: earlier).succeeded)
    }

    func testShowsListeningAndTranscribingWhileItHappens() {
        XCTAssertEqual(step(activity: .recording).phase, .listening)
        XCTAssertEqual(step(activity: .transcribing).phase, .transcribing)
        XCTAssertEqual(step(activity: .recording).phaseLine, "Listening… let go of F5 when you're done.")
        XCTAssertEqual(step(activity: .transcribing).phaseLine, "Transcribing…")
    }

    func testANewDictationIsShownInTheWizardsFieldAndCountsAsSuccess() {
        let heard = step(baseline: earlier, entry: fresh, insertion: .pasted)
        XCTAssertEqual(heard.phase, .heard)
        XCTAssertEqual(heard.heardText, "Testing one two three.")
        XCTAssertTrue(heard.succeeded)
        XCTAssertEqual(heard.insertionLine, "Typed into the app you were in.")
        XCTAssertEqual(heard.insertionTone, .success)
    }

    /// VoiceBar never types into itself; a dictation with the wizard in front is heard but not typed anywhere.
    func testNotTypedAnywhereExplainsWhereVoiceBarTypes() {
        for status in [DictationInsertionStatus.failed, .notInserted] {
            let heard = step(entry: fresh, insertion: status)
            XCTAssertTrue(heard.succeeded, "\(status): hearing it proves permissions, F5, the mic and transcription")
            XCTAssertEqual(
                heard.insertionLine,
                "It wasn't typed anywhere: VoiceBar types into the app you were in, not into this window. "
                    + "Click into Notes or TextEdit and try again.",
                "\(status)"
            )
            XCTAssertEqual(heard.insertionTone, .attention)
        }
    }

    func testAnEmptyTranscriptPointsAtTheMicrophone() {
        let silent = step(entry: RecentTranscriptionEntry(text: "  ", createdAt: Date(timeIntervalSince1970: 300)))
        XCTAssertFalse(silent.succeeded)
        XCTAssertEqual(
            silent.problems,
            [SetupTryItProblem(step: .microphone, text: "VoiceBar heard nothing. Check your microphone.")]
        )
    }

    func testEachUnfinishedStepIsNamedWithWhereToFixIt() {
        let broken = step(readiness: SetupReadiness(
            permissions: SetupPermissionSnapshot(
                microphone: .denied, accessibilityGranted: true, inputMonitoringGranted: true,
                hotkeyListenerActive: false
            ),
            f5Key: SetupF5KeyStatus(listenerActive: false, helperInstalled: false),
            microphoneName: nil
        ))
        XCTAssertEqual(broken.problems, [
            SetupTryItProblem(step: .permissions, text: "Allow access isn't finished."),
            SetupTryItProblem(step: .f5Key, text: "F5 isn't on yet."),
            SetupTryItProblem(step: .microphone, text: "No microphone found."),
        ])
        XCTAssertEqual(broken.problems.map(\.fixTitle), ["Go to Allow access", "Go to F5 key", "Go to Microphone"])
    }

    func testAMissingHelperAloneIsNotAProblem() {
        let noHelper = step(readiness: SetupReadiness(
            permissions: .allGranted,
            f5Key: SetupF5KeyStatus(listenerActive: true, helperInstalled: false),
            microphoneName: "Studio USB Mic"
        ))
        XCTAssertEqual(noHelper.problems, [], "F5 is listened for directly; the helper is for the dictation key")
    }
}
