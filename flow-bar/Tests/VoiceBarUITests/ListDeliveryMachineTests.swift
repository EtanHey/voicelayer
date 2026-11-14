import XCTest
@testable import VoiceBarUI

@MainActor final class ListDeliveryMachineTests: XCTestCase {
    @MainActor final class Harness {
        var time: TimeInterval = 0
        var front = true
        var pending: [(ListDeliveryMachine.Request, (ListDeliveryMachine.Reply) -> Void)] = []
        var timers: [() -> Void] = []
        var posts: [String] = []
        var outcomes: [ListDeliveryMachine.Outcome] = []
        lazy var machine = ListDeliveryMachine(now: { self.time }, schedule: { _, action in self.timers.append(action) })
        func start(_ text: String = "1. Alpha\n2. Beta") {
            machine.deliver(text, env: .init(worker: { self.pending.append(($0, $1)) },
                guardTarget: { self.front }, post: { self.posts.append($0); return .posted }),
                completion: { self.outcomes.append($0) })
        }
        func reply(same: Bool = true, value: String? = "", age: TimeInterval = 0) {
            let (r, callback) = pending.removeFirst()
            callback(.init(request: r, same: same, value: value, completed: time - age))
        }
        func firstPost() { start(); reply(); reply() }
        func expire() { time = 0.25; timers[0]() }
    }
    func testCheckAwaitPostAndFirstUnguarded() {
        let h = Harness(); h.start(); h.reply(); h.front = false; h.reply()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.refused])
    }
    func testForeignReadNeverDropsMarker() {
        let h = Harness(); h.firstPost()
        h.reply(same: false, value: "1. Alpha\n2. "); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"])
        XCTAssertEqual(h.outcomes, [.posted])
    }
    func testInsertedMarkerAndConservation() {
        let h = Harness(); h.firstPost(); h.reply(value: "1. Alpha\n2. "); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "Beta"]); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testAgedCheckRequestsFreshCheck() {
        let h = Harness(); h.start(); h.reply(); h.time = 0.15; h.reply(age: 0.15)
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.pending.count, 1)
        h.reply(); XCTAssertEqual(h.posts, ["1. Alpha\n"])
    }
    func testSilentCaptureDeadlineAndBatchGuard() {
        let h = Harness(); h.start(); h.front = false; h.expire()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.refused])
    }
    func testSilentCaptureUsesOldBatch() {
        let h = Harness(); h.start(); h.expire()
        XCTAssertEqual(h.posts, ["1. Alpha\n2. Beta"]); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testSilentCheckRefusesAtDeadlineNoAXAfterExpiry() {
        let h = Harness(); h.start(); h.reply(); h.expire(); h.reply()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.refused]); XCTAssertEqual(h.pending.count, 0)
    }
    func testSilentReadDeadlinePartialNoLostCharacterOrDropSlow() {
        let h = Harness(); h.firstPost(); h.expire()
        XCTAssertEqual(h.outcomes, [.partial(delivered: "1. Alpha\n", remaining: "2. Beta")])
        h.reply(value: "1. Alpha\n2. ")
        XCTAssertEqual(h.posts, ["1. Alpha\n"]); XCTAssertEqual(h.outcomes.count, 1)
    }
    func testFreshCheckAtExpiryKeepsAllMarkers() {
        let h = Harness(); h.firstPost(); h.reply(value: "1. Alpha\n2. "); h.time = 0.25; h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"]); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testUnknownAndPreBreakKeepMarker() {
        for value in ["1. Alpha", "unknown", "1. Alpha\n"] {
            let h = Harness(); h.firstPost(); h.reply(value: value); h.reply()
            XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"])
        }
    }
    func testFallbackGuard() {
        let h = Harness(); h.firstPost(); h.reply(same: false); h.front = false; h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n"])
        XCTAssertEqual(h.outcomes, [.partial(delivered: "1. Alpha\n", remaining: "2. Beta")])
    }
    func testPlainTextZeroAXOnePost() {
        let h = Harness(); h.start("Alpha")
        XCTAssertEqual(h.posts, ["Alpha"]); XCTAssertEqual(h.pending.count, 0); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testMainWaitRecordingWatchdogQuitRemainRunnable() async {
        let h = Harness()
        let started = ProcessInfo.processInfo.systemUptime
        h.start()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.05)
        let recording = expectation(description: "recording start while worker is silent")
        let watchdog = expectation(description: "watchdog while worker is silent")
        DispatchQueue.main.async { recording.fulfill() }
        DispatchQueue.main.async { watchdog.fulfill() }
        await fulfillment(of: [recording, watchdog], timeout: 0.1)
        h.machine.close()
        XCTAssertEqual(h.outcomes, [.refused])
        h.reply(); XCTAssertEqual(h.outcomes.count, 1); XCTAssertEqual(h.posts, [])
    }
    func testOverflowAndClosedIngressAreRefusedOnceEach() {
        let h = Harness(); h.start(); h.start(); h.start(); h.start()
        XCTAssertEqual(h.outcomes, [.refused])
        h.machine.close(); h.machine.close(); h.start()
        XCTAssertEqual(h.outcomes, Array(repeating: .refused, count: 5))
    }
    func testDrainClosesPrefixAndTwoQueuedExactlyOnce() {
        let h = Harness(); h.firstPost(); h.start(); h.start(); h.machine.close()
        XCTAssertEqual(h.outcomes, [.partial(delivered: "1. Alpha\n", remaining: "2. Beta"), .refused, .refused])
        h.reply(); XCTAssertEqual(h.outcomes.count, 3); XCTAssertFalse(h.machine.isActive)
    }
    func testFIFOAndOldIdDiscarded() {
        let h = Harness(); h.start(); h.start("Alpha"); h.start("Beta")
        h.expire(); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n2. Beta", "Alpha", "Beta"])
        XCTAssertEqual(h.outcomes, [.posted, .posted, .posted])
    }
    func testOldStepDiscarded() {
        let h = Harness(); h.start(); h.reply()
        let old = h.pending[0]; h.reply()
        old.1(.init(request: old.0, same: true, value: "", completed: 0))
        XCTAssertEqual(h.posts, ["1. Alpha\n"])
    }
}
