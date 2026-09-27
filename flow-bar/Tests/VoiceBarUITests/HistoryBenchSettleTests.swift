import Foundation
@testable import VoiceBarUI
import XCTest

/// E review r1, M1: the History benchmark reported a required load that took 800 ms as a 0 ms settle. These pin
/// the settle rules deterministically (loads are faked on a background queue), with no archive and no env var.
@MainActor
final class HistoryBenchSettleTests: XCTestCase {
    private func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func testASlowRequiredLoadIsWaitedForAndReportedAtItsRealTime() throws {
        let probe = HistoryBenchProbe()
        let start = CFAbsoluteTimeGetCurrent()
        schedule(after: 0.02) { probe.start("dictations") }
        schedule(after: 0.8) { probe.finish("dictations") }

        let result = HistoryBenchSettle.settle(after: start, expecting: .load("dictations"), probe: probe)

        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.loaderDoneMs), 750)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.quietAtMs), 750)
    }

    func testARequiredLoadThatNeverFinishesTimesOutInsteadOfLookingFast() {
        let probe = HistoryBenchProbe()
        schedule(after: 0.02) { probe.start("dictations") }

        let result = HistoryBenchSettle.settle(
            after: CFAbsoluteTimeGetCurrent(), expecting: .load("dictations"), probe: probe, timeout: 1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.quietAtMs)
    }

    func testASwitchWhoseLoadStartsWaitsForItToFinish() throws {
        let probe = HistoryBenchProbe()
        let start = CFAbsoluteTimeGetCurrent()
        schedule(after: 0.02) { probe.start("ask") }
        schedule(after: 0.8) { probe.finish("ask") }

        let result = HistoryBenchSettle.settle(after: start, expecting: .loadIfStarted("ask"), probe: probe)

        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.loaderDoneMs), 750)
    }

    func testASwitchThatStartsNoLoadSettlesWithoutOne() throws {
        let probe = HistoryBenchProbe()

        let result = HistoryBenchSettle.settle(
            after: CFAbsoluteTimeGetCurrent(), expecting: .loadIfStarted("ask"), probe: probe
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.loaderDoneMs)
        XCTAssertLessThan(try XCTUnwrap(result.quietAtMs), 100, "no load and a quiet main thread")
    }

    func testAnEarlierLoadDoesNotSatisfyTheNextOperation() {
        let probe = HistoryBenchProbe()
        probe.start("dictations")
        probe.finish("dictations")
        probe.reset("dictations")

        let result = HistoryBenchSettle.settle(
            after: CFAbsoluteTimeGetCurrent(), expecting: .load("dictations"), probe: probe, timeout: 0.6
        )

        XCTAssertTrue(result.timedOut)
    }
}
