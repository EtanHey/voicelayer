import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// BARE-STOP H2 (REVIEW-817 §1c-ii): a double-tap whose first press lasts 160-250 ms crosses the hold threshold,
/// starts a push-to-talk take, and its release used to stop that take ~25 ms in: a header-only (44-byte) archive,
/// then a fresh take from the second tap. The release now waits out the double-tap window, so the second press
/// locks the take the first press started. Holds past 250 ms, quick double-taps and mouse gestures are unchanged.
final class SlowFirstTapGestureTests: XCTestCase {
    private final class Timeline {
        let gesture = GestureStateMachine()
        var ms = 0
        var jobs: [(Int, DispatchWorkItem)] = []
        var starts = 0, stops = 0, locks = 0, singles = 0, cancels = 0
        var logical: [HotkeyPhase] = []

        init() {
            gesture.clock = { [unowned self] in Double(self.ms) / 1000 }
            gesture.schedule = { [unowned self] delay, job in self.jobs.append((self.ms + delay, job)) }
            gesture.onHoldStart = { [unowned self] in starts += 1 }
            gesture.onHoldEnd = { [unowned self] in stops += 1 }
            gesture.onDoubleTap = { [unowned self] in locks += 1 }
            gesture.onSingleTap = { [unowned self] in singles += 1 }
            gesture.onCancel = { [unowned self] in cancels += 1 }
            gesture.onLogicalPhaseChange = { [unowned self] in logical.append($0) }
        }

        func advance(to target: Int) {
            while let i = jobs.indices.filter({ jobs[$0].0 <= target }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
                let (deadline, job) = jobs.remove(at: i)
                ms = deadline
                job.perform()
            }
            ms = target
        }
        func down(at t: Int) { advance(to: t); gesture.handleKeyDown() }
        func up(at t: Int) { advance(to: t); gesture.handleKeyUp() }
    }

    /// The reviewer's sequence: down 0 → hold timer 160 → up 185 → down 340 → up 420.
    func testSlowFirstTapThenSecondTapLocksTheTakeTheFirstPressStarted() {
        let t = Timeline()
        t.down(at: 0); t.up(at: 185); t.down(at: 340); t.up(at: 420)
        t.advance(to: 1_200)
        XCTAssertEqual(t.starts, 1, "one take")
        XCTAssertEqual(t.stops, 0, "the first release must not stop the take it started")
        XCTAssertEqual(t.locks, 1)
        XCTAssertEqual(t.gesture.state, .locked)
        XCTAssertFalse(t.logical.contains(.awaitingSecondTap), "a recording take never shows the lock hint")
        t.gesture.handleKeyDown() // locked: the next press stops it
        XCTAssertEqual(t.stops, 1)
    }

    func testEverySlowFirstPressInTheBandLocksOnASecondTap() {
        for press in stride(from: 165, to: GestureStateMachine.ambiguousHoldReleaseMs, by: 15) {
            for gap in [60, 150, 300] {
                let t = Timeline()
                t.down(at: 0); t.up(at: press); t.down(at: press + gap); t.up(at: press + gap + 80)
                t.advance(to: 2_000)
                XCTAssertEqual([t.starts, t.stops, t.locks], [1, 0, 1], "press=\(press) gap=\(gap)")
                XCTAssertEqual(t.gesture.state, .locked, "press=\(press) gap=\(gap)")
            }
        }
    }

    func testShortHoldAloneStillStopsWhenTheWindowCloses() {
        let t = Timeline()
        t.down(at: 0); t.up(at: 200)
        XCTAssertEqual(t.stops, 0)
        XCTAssertEqual(t.gesture.state, .waitingForDoubleTap)
        t.advance(to: 200 + GestureStateMachine.doubleTapWindowMs)
        XCTAssertEqual([t.starts, t.stops, t.locks, t.singles], [1, 1, 0, 0])
        XCTAssertEqual(t.gesture.state, .idle)
    }

    func testLateSecondPressAfterTheWindowStopsThenStartsFresh() {
        let t = Timeline()
        t.down(at: 0); t.up(at: 200)
        t.ms = 200 + GestureStateMachine.doubleTapWindowMs + 1 // timer not yet delivered
        t.gesture.handleKeyDown()
        XCTAssertEqual([t.starts, t.stops, t.locks], [1, 1, 0])
        XCTAssertEqual(t.gesture.state, .pressing)
    }

    func testDeliberateHoldPastTheBandStopsImmediately() {
        let t = Timeline()
        t.down(at: 0); t.up(at: GestureStateMachine.ambiguousHoldReleaseMs)
        XCTAssertEqual([t.starts, t.stops], [1, 1])
        XCTAssertEqual(t.gesture.state, .idle)
    }

    func testEscapeDuringTheDeferredReleaseCancelsTheTake() {
        let t = Timeline()
        t.down(at: 0); t.up(at: 190)
        t.gesture.cancel()
        XCTAssertEqual([t.stops, t.cancels], [0, 1])
        t.advance(to: 1_000)
        XCTAssertEqual(t.stops, 0, "a cancelled window never stops later")
        XCTAssertEqual(t.gesture.state, .idle)
    }

    func testProgrammaticReleaseIsNeverAnAmbiguousTap() {
        let t = Timeline()
        t.down(at: 0); t.advance(to: 190); t.gesture.handleKeyUp(deferAmbiguousHold: false)
        XCTAssertEqual([t.starts, t.stops], [1, 1], "the legacy local-control stopRecording stops at once")
        XCTAssertEqual(t.gesture.state, .idle)
    }

    func testQuickDoubleTapIsUnchanged() {
        let t = Timeline()
        t.down(at: 0); t.up(at: 80); t.down(at: 200); t.up(at: 260)
        t.advance(to: 1_000)
        XCTAssertEqual([t.starts, t.stops, t.locks], [1, 0, 1])
        XCTAssertEqual(t.gesture.state, .locked)
    }
}
