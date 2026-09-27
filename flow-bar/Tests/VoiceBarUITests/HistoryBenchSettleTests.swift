import Foundation
@testable import VoiceBarUI
import XCTest

/// E review r1, M1: the History benchmark reported a required load that took 800 ms as a 0 ms settle. These pin
/// the settle rule on synthetic timelines — no run loop, clock or NSApp (review r3: run-loop-driven versions timed
/// out on the headless CI runner, whose slices never read as quiet).
final class HistoryBenchSettleTests: XCTestCase {
    /// Loader marks and busy stretches on a virtual timeline, in seconds from the operation's start.
    private struct Timeline {
        var started: TimeInterval?
        var finished: TimeInterval?
        /// (start, end) of main-thread busy stretches, each observed as one long slice.
        var busy: [(TimeInterval, TimeInterval)] = []
    }

    /// Replays `timeline` through the rule in 2 ms slices (a busy stretch is one slice) until it settles or `timeout`.
    private func simulate(
        _ expecting: HistoryBenchExpectation,
        _ timeline: Timeline,
        timeout: TimeInterval = 10
    ) -> HistoryBenchSettled {
        let origin: CFAbsoluteTime = 1000
        var rule = HistoryBenchSettleRule(start: origin, expecting: expecting)
        var now: TimeInterval = 0
        while now < timeout {
            var end = now + 0.002
            if let stretch = timeline.busy.first(where: { $0.0 <= now && now < $0.1 }) { end = stretch.1 }
            let mark = { (time: TimeInterval?) in time.flatMap { $0 <= end ? origin + $0 : nil } }
            if let settled = rule.observe(
                sliceStart: origin + now, sliceEnd: origin + end,
                started: mark(timeline.started), finished: mark(timeline.finished)
            ) {
                return settled
            }
            now = end
        }
        return rule.timedOut()
    }

    func testASlowRequiredLoadIsWaitedForAndReportedAtItsRealTime() throws {
        let result = simulate(.load("dictations"), Timeline(started: 0.02, finished: 0.8))

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(try XCTUnwrap(result.loaderDoneMs), 800, accuracy: 2.5)
        XCTAssertEqual(try XCTUnwrap(result.quietAtMs), 800, accuracy: 2.5, "never 0 for a load that took 800 ms")
    }

    func testMainThreadWorkAfterTheLoadExtendsTheSettleToItsEnd() throws {
        let result = simulate(.load("dictations"), Timeline(started: 0.02, finished: 0.3, busy: [(0.3, 0.36)]))

        XCTAssertEqual(try XCTUnwrap(result.quietAtMs), 360, accuracy: 2.5, "rows render after the page lands")
        XCTAssertEqual(result.longestStallMs, 60, accuracy: 0.5)
    }

    func testARequiredLoadThatNeverFinishesTimesOutInsteadOfLookingFast() {
        let result = simulate(.load("dictations"), Timeline(started: 0.02), timeout: 1)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.quietAtMs)
    }

    func testASwitchWhoseLoadStartsWaitsForItToFinish() throws {
        let result = simulate(.loadIfStarted("ask"), Timeline(started: 0.02, finished: 0.8))

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(try XCTUnwrap(result.loaderDoneMs), 800, accuracy: 2.5)
    }

    func testASwitchWhoseLoadStartsLateStillWaitsForIt() throws {
        // Started after most of the no-load window: still a load, still awaited.
        let result = simulate(.loadIfStarted("ask"), Timeline(started: 0.39, finished: 1.2))

        XCTAssertEqual(try XCTUnwrap(result.loaderDoneMs), 1200, accuracy: 2.5)
    }

    func testASwitchThatStartsNoLoadSettlesWithoutOne() throws {
        let result = simulate(.loadIfStarted("ask"), Timeline(busy: [(0, 0.02)]))

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.loaderDoneMs)
        XCTAssertEqual(try XCTUnwrap(result.quietAtMs), 20, accuracy: 2.5, "the switch's own main-thread work")
    }

    func testALoadThatFinishedBeforeTheOperationIsClampedNeverNegative() throws {
        let origin: CFAbsoluteTime = 1000
        var rule = HistoryBenchSettleRule(start: origin, expecting: .load("ask"))
        var settled: HistoryBenchSettled?
        var now: TimeInterval = 0
        while settled == nil, now < 1 {
            settled = rule.observe(sliceStart: origin + now, sliceEnd: origin + now + 0.002,
                                   started: origin - 0.1, finished: origin - 0.05)
            now += 0.002
        }

        XCTAssertEqual(try XCTUnwrap(settled?.loaderDoneMs), 0, accuracy: 0.001)
    }

    /// The probe side: a reset forgets earlier loads, so they can't satisfy the next operation.
    func testAResetProbeReportsNoEarlierLoad() {
        let probe = HistoryBenchProbe()
        probe.start("dictations")
        probe.finish("dictations")
        probe.reset("dictations")

        XCTAssertNil(probe.started("dictations"))
        XCTAssertNil(probe.finished("dictations"))
    }
}
