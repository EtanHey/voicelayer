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

    /// #210 r1: `.failed` also comes from a paste-handler failure, an AX timeout or a competing insertion with the
    /// target focused, so its guidance names no single cause.
    func testAFailedInsertionGetsNeutralGuidance() {
        let heard = step(entry: fresh, insertion: .failed)
        XCTAssertTrue(heard.succeeded, "hearing it proves permissions, F5, the mic and transcription")
        XCTAssertEqual(
            heard.insertionLine,
            "VoiceBar heard you but couldn't type it. Put the cursor in a text box in another app and try again; "
                + "if it keeps failing, check Accessibility in Allow access."
        )
        XCTAssertEqual(heard.insertionTone, .attention)
    }

    /// `.notInserted`: VoiceBar didn't try to type this one. The line says what to do, not why.
    func testANotInsertedDictationAsksForAnotherTryInAnotherApp() {
        let heard = step(entry: fresh, insertion: .notInserted)
        XCTAssertTrue(heard.succeeded)
        XCTAssertEqual(
            heard.insertionLine,
            "It wasn't typed anywhere. Click into Notes or TextEdit, hold F5, and try again."
        )
        XCTAssertEqual(heard.insertionTone, .attention)
    }

    /// #210 r1: the real empty final. VoiceState fails the transcription (mode .error, "Transcription failed") and
    /// remembers no entry; the wizard must not read that as "still waiting".
    func testAnEmptyAttemptPointsAtTheMicrophoneAndStaysUntilTheNextTry() {
        var tracker = SetupTryItTracker(first: SetupTryItObservation(
            entry: earlier,
            insertion: .pasted,
            activity: .idle
        ))
        let failed = SetupTryItObservation(
            entry: earlier, insertion: .pasted, activity: .idle, failure: "Transcription failed"
        )
        tracker.observe(failed)
        let shown = SetupTryItStep(tracker: tracker, observation: failed, readiness: ready)
        XCTAssertEqual(shown.phase, .failed)
        XCTAssertFalse(shown.succeeded)
        XCTAssertEqual(shown.problems, [
            SetupTryItProblem(step: .microphone, text: "VoiceBar heard nothing. Check your microphone."),
        ])

        // The error clears back to idle a moment later; the guidance stays until the next attempt.
        let settled = SetupTryItObservation(entry: earlier, insertion: .pasted, activity: .idle)
        tracker.observe(settled)
        XCTAssertEqual(SetupTryItStep(tracker: tracker, observation: settled, readiness: ready).phase, .failed)

        let retry = SetupTryItObservation(entry: earlier, insertion: .pasted, activity: .recording)
        tracker.observe(retry)
        XCTAssertEqual(SetupTryItStep(tracker: tracker, observation: retry, readiness: ready).phase, .listening)
        tracker.observe(settled)
        XCTAssertEqual(SetupTryItStep(tracker: tracker, observation: settled, readiness: ready).phase, .waiting)
    }

    func testAnotherFailureSaysWhatWentWrong() {
        var tracker = SetupTryItTracker(first: .none)
        let failed = SetupTryItObservation(
            entry: nil, insertion: .unverified, activity: .idle, failure: "Unable to start recording"
        )
        tracker.observe(failed)
        XCTAssertEqual(SetupTryItStep(tracker: tracker, observation: failed, readiness: ready).problems, [
            SetupTryItProblem(
                step: .microphone, text: "That try didn't work (Unable to start recording). Check your microphone."
            ),
        ])
    }

    func testAFailureAlreadyShowingWhenTheStepOpensIsNotThisStepsAttempt() {
        let tracker = SetupTryItTracker(first: SetupTryItObservation(
            entry: nil, insertion: .unverified, activity: .idle, failure: "Transcription failed"
        ))
        XCTAssertNil(tracker.failure)
    }

    func testTheNextDictationReplacesAFailure() {
        var tracker = SetupTryItTracker(first: .none)
        tracker.observe(SetupTryItObservation(entry: nil, insertion: .unverified, activity: .idle,
                                              failure: "Transcription failed"))
        let heard = SetupTryItObservation(entry: fresh, insertion: .pasted, activity: .idle)
        tracker.observe(heard)
        let step = SetupTryItStep(tracker: tracker, observation: heard, readiness: ready)
        XCTAssertEqual(step.phase, .heard)
        XCTAssertEqual(step.heardText, "Testing one two three.")
    }

    /// Like #208 r2's helper run: the baseline and a failure live on the controller, so leaving Try it and coming
    /// back neither forgets this step's dictation nor re-counts an old one.
    func testTheControllerKeepsTryItAcrossStepChanges() throws {
        let suite = "SetupWizardTryItLifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SetupWizardController(
            store: SetupWizardCompletionStore(defaults: defaults),
            model: SetupWizardModel(step: .tryIt)
        )
        controller.observeTryIt(SetupTryItObservation(entry: earlier, insertion: .pasted, activity: .idle))
        controller.observeTryIt(SetupTryItObservation(entry: fresh, insertion: .pasted, activity: .idle))
        controller.goBack()
        controller.continueToNextStep()
        let later = SetupTryItObservation(entry: fresh, insertion: .pasted, activity: .idle)
        controller.observeTryIt(later)
        let tracker = try XCTUnwrap(controller.tryIt)
        XCTAssertEqual(tracker.baseline, earlier)
        XCTAssertEqual(SetupTryItStep(tracker: tracker, observation: later, readiness: ready).heardText,
                       "Testing one two three.")
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
