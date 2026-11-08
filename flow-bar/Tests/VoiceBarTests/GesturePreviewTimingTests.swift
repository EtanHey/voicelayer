import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class GesturePreviewTimingTests: XCTestCase {
    private final class Timeline {
        let gesture: GestureStateMachine
        var ms = 0
        var jobs: [(Int, DispatchWorkItem)] = []
        var phases: [HotkeyPhase] = []
        var statuses: [String] = []

        init(doubleTapWindowMs: Int = 400, holdThresholdMs: Int = 160) {
            gesture = GestureStateMachine(doubleTapWindowMs: doubleTapWindowMs, holdThresholdMs: holdThresholdMs)
            gesture.clock = { [unowned self] in Double(self.ms) / 1000 }
            gesture.schedule = { [unowned self] delay, job in self.jobs.append((self.ms + delay, job)) }
            gesture.onPreviewPhaseChange = { [unowned self] phase in
                self.phases.append(phase)
                self.statuses.append(VoiceBarPresentation.idleStatusText(
                    transcript: "", confirmationText: nil, hotkeyPhase: phase, hotkeyEnabled: true))
            }
        }

        func advance(to target: Int) {
            while let i = jobs.indices.filter({ jobs[$0].0 <= target }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
                let (deadline, job) = jobs.remove(at: i)
                ms = deadline
                job.perform()
            }
            ms = target
        }
    }

    func testQuickDoubleTapNeverEmitsOrPresentsTapAgainHint() {
        for gap in [0, 50, 200, 250, 300, 350] {
            let t = Timeline()
            var starts = 0
            var locks = 0
            t.gesture.onHoldStart = { starts += 1 }
            t.gesture.onDoubleTap = { locks += 1 }
            t.gesture.handleKeyDown()
            t.advance(to: 80)
            t.gesture.handleKeyUp()
            t.advance(to: 80 + gap)
            t.gesture.handleKeyDown()
            t.gesture.handleKeyUp()
            t.advance(to: 600) // cancelled preview/hold/window jobs must stay inert
            XCTAssertEqual(t.gesture.state, .locked, "gap=\(gap)")
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(locks, 1)
            XCTAssertFalse(t.phases.contains(.awaitingSecondTap), "gap=\(gap)")
            XCTAssertFalse(t.statuses.contains(VoiceBarPresentation.tapAgainToLockHint))
            t.gesture.reset()
        }
    }

    func testSingleTapDoesNotShowFiftyMillisecondHintFlash() {
        let t = Timeline()
        var singles = 0
        t.gesture.onSingleTap = { singles += 1 }
        t.gesture.handleKeyDown()
        t.advance(to: 80)
        t.gesture.handleKeyUp()
        t.advance(to: 479)
        XCTAssertEqual(t.gesture.state, .waitingForDoubleTap)
        XCTAssertEqual(singles, 0)
        t.advance(to: 480)
        XCTAssertEqual(t.gesture.state, .idle)
        XCTAssertEqual(singles, 1)
        XCTAssertFalse(t.phases.contains(.awaitingSecondTap))
        XCTAssertFalse(t.statuses.contains(VoiceBarPresentation.tapAgainToLockHint))
    }

    func testShortTapDoesNotShowHoldToTalkFlash() {
        for duration in [50, 100, 120, 150, 159] {
            let t = Timeline()
            t.gesture.handleKeyDown()
            t.advance(to: duration)
            t.gesture.handleKeyUp()
            t.advance(to: duration + 400)
            XCTAssertFalse(t.phases.contains(.pressing), "duration=\(duration)")
            XCTAssertFalse(t.statuses.contains(VoiceBarPresentation.holdToTalkHint))
            XCTAssertEqual(t.gesture.state, .idle)
        }
    }

    func testFutureLongerWindowsAllowMeaningfulHintsAfterGrace() {
        XCTAssertNil(GestureStateMachine.previewDelayMs(graceMs: 350, windowMs: 400))
        XCTAssertNil(GestureStateMachine.previewDelayMs(graceMs: 120, windowMs: 160))
        XCTAssertNil(GestureStateMachine.previewDelayMs(graceMs: 350, windowMs: 500))
        XCTAssertEqual(GestureStateMachine.previewDelayMs(graceMs: 350, windowMs: 501), 351)
        XCTAssertEqual(GestureStateMachine.previewDelayMs(graceMs: 350, windowMs: 800), 351)
    }

    func testLongWindowHintLastsAtLeastMinimumThenSecondPressClearsIt() throws {
        let t = Timeline(doubleTapWindowMs: 800)
        t.gesture.handleKeyDown()
        t.advance(to: 80)
        t.gesture.handleKeyUp()
        let hintJob = try XCTUnwrap(t.jobs.first { $0.0 == 431 }?.1)
        t.advance(to: 430)
        XCTAssertFalse(t.phases.contains(.awaitingSecondTap))
        t.advance(to: 431)
        XCTAssertEqual(t.phases.last, .awaitingSecondTap)
        t.advance(to: 581) // visible for 150 ms; the next press still resolves immediately
        XCTAssertEqual(t.phases.last, .awaitingSecondTap)
        t.gesture.handleKeyDown()
        XCTAssertEqual(t.gesture.state, .locked)
        XCTAssertEqual(t.phases.last, .holding)
        hintJob.perform() // force a stale queued callback after cancellation
        t.advance(to: 1000)
        XCTAssertEqual(t.phases.filter { $0 == .awaitingSecondTap }.count, 1)
        XCTAssertEqual(t.phases.last, .holding)
        t.gesture.reset()
    }

    func testStaleDisplayedHintCannotOutliveLogicalReset() {
        let voice = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        voice.hotkeyEnabled = true
        voice.setHotkeyPhase(.awaitingSecondTap)
        voice.setHotkeyPreviewPhase(.awaitingSecondTap)
        XCTAssertEqual(voice.presentedHotkeyPhase, .awaitingSecondTap)
        voice.setHotkeyPhase(.idle)
        voice.setHotkeyPreviewPhase(.awaitingSecondTap)
        XCTAssertEqual(voice.presentedHotkeyPhase, .idle)
        voice.setHotkeyPhase(.holding)
        voice.setHotkeyPreviewPhase(.pressing)
        XCTAssertEqual(voice.presentedHotkeyPhase, .idle)
    }

    func testLogicalPhasesAndHoldThresholdStayImmediate() {
        let t = Timeline()
        var phases: [HotkeyPhase] = []
        var times: [Int] = []
        t.gesture.onLogicalPhaseChange = { phase in phases.append(phase); times.append(t.ms) }
        var starts = 0
        var stops = 0
        t.gesture.onHoldStart = { starts += 1 }
        t.gesture.onHoldEnd = { stops += 1 }
        t.gesture.handleKeyDown()
        XCTAssertEqual(phases, [.pressing])
        t.advance(to: 159)
        XCTAssertEqual(starts, 0)
        t.advance(to: 160)
        XCTAssertEqual(starts, 1)
        t.advance(to: 200)
        t.gesture.handleKeyUp()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(phases, [.pressing, .holding, .idle])
        XCTAssertEqual(times, [0, 160, 200])
        XCTAssertEqual(t.phases, [.idle, .holding, .idle])
    }

    func testLogicalPressStillCancelsSelectionCaptureBeforeAnyHint() {
        let t = Timeline()
        let voice = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        voice.hotkeyEnabled = true
        voice.isConnected = true
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands = 0
        voice.sendCommand = { _ in commands += 1 }
        voice.selectionTextCaptureHandler = { completion = $0 }
        voice.speakSelection()
        XCTAssertNotNil(completion)
        t.gesture.onLogicalPhaseChange = { voice.setHotkeyPhase($0) }
        t.gesture.onPreviewPhaseChange = { voice.setHotkeyPreviewPhase($0) }
        t.gesture.handleKeyDown()
        XCTAssertEqual(voice.hotkeyPhase, .pressing)
        XCTAssertEqual(voice.presentedHotkeyPhase, .idle)
        t.advance(to: 80)
        t.gesture.handleKeyUp()
        XCTAssertEqual(voice.hotkeyPhase, .awaitingSecondTap)
        XCTAssertEqual(voice.presentedHotkeyPhase, .idle)
        t.advance(to: 480)
        completion?(.completed("cancelled selection"))
        XCTAssertEqual(commands, 0, "logical F5 cancels even after the phase returns to idle")
        XCTAssertEqual(voice.hotkeyPhase, .idle)
        XCTAssertEqual(voice.presentedHotkeyPhase, .idle)
    }
}
