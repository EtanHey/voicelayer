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
            guard !pending.isEmpty else { XCTFail("Expected outstanding AX request"); return }
            let (r, callback) = pending.removeFirst()
            callback(.init(request: r, same: same, value: value, completed: time - age))
        }
        func firstPost() { start(); reply(); reply() }
        func expire() { time = 0.4; timers[0]() }
    }
    func testCheckAwaitPostAndFirstUnguarded() {
        let h = Harness(); h.start(); h.reply(); h.front = false; h.reply()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.refused])
    }
    func testForeignReadNeverDropsMarker() {
        let h = Harness(); h.firstPost()
        h.reply(same: false, value: "1. Alpha\n2. "); h.time = 0.015; h.timers.last?(); h.reply(value: "1. Alpha\n"); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"])
        XCTAssertEqual(h.outcomes, [.posted])
    }
    func testInsertedMarkerAndConservation() {
        let h = Harness(); h.firstPost(); h.reply(value: "1. Alpha\n2. "); h.timers.last?(); h.reply(value: "1. Alpha\n2. "); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "Beta"]); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testAgedCheckRequestsFreshCheck() {
        let h = Harness(); h.start(); h.reply(); h.time = 0.15; h.reply(age: 0.15)
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.pending.count, 1)
        h.reply(); XCTAssertEqual(h.posts, ["1. Alpha\n"])
    }
    func testSilentCaptureDeadlineAndBatchGuard() {
        let h = Harness(); h.start(); h.front = false; h.expire()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.declined])
    }
    func testSilentCaptureDeclinesWithoutPost() {
        let h = Harness(); h.start(); h.expire()
        XCTAssertEqual(h.posts, []); XCTAssertEqual(h.outcomes, [.declined])
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
        let h = Harness(); h.firstPost(); h.reply(value: "1. Alpha\n2. "); h.timers.last?(); h.reply(value: "1. Alpha\n2. "); h.time = 0.4; h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"]); XCTAssertEqual(h.outcomes, [.posted])
    }
    func testUnknownAndPreBreakKeepMarker() {
        for value in ["1. Alpha", "unknown", "1. Alpha\n"] {
            let h = Harness(); h.firstPost(); h.reply(value: value); if h.pending.isEmpty { h.timers.last?(); h.reply(value: "1. Alpha\n") }; h.reply()
            XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta"])
        }
    }
    func testFallbackGuard() {
        let h = Harness(); h.firstPost(); h.reply(value: "1. Alpha\n"); h.front = false; h.reply()
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
        XCTAssertEqual(h.posts, ["Alpha", "Beta"])
        XCTAssertEqual(h.outcomes, [.declined, .posted, .posted])
    }
    func testOldStepDiscarded() {
        let h = Harness(); h.start(); h.reply()
        let old = h.pending[0]; h.reply()
        old.1(.init(request: old.0, same: true, value: "", completed: 0))
        XCTAssertEqual(h.posts, ["1. Alpha\n"])
    }
    func testReentrantCompletionCannotBypassFIFO() {
        let h = Harness()
        h.machine.deliver("1. Alpha\n2. Beta", env: .init(worker: { h.pending.append(($0, $1)) },
            guardTarget: { true }, post: { h.posts.append($0); return .posted }), completion: { _ in h.start("Gamma") })
        h.start("Alpha"); h.start("Beta")
        h.reply(); h.reply(); h.reply(value: "1. Alpha\n"); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "2. Beta", "Alpha", "Beta", "Gamma"])
    }
    func testUnknownRereadsAndInsertedNeedsTwoEqualReadings() {
        let h = Harness(); h.firstPost(); h.reply(value: "")
        XCTAssertTrue(h.pending.isEmpty); XCTAssertEqual(h.posts.count, 1)
        h.time = 0.015; h.timers.last?(); h.reply(value: "1. Alpha\n2. ")
        XCTAssertTrue(h.pending.isEmpty)
        h.time = 0.030; h.timers.last?(); h.reply(value: "1. Alpha\n2. "); h.reply()
        XCTAssertEqual(h.posts, ["1. Alpha\n", "Beta"])
    }
    func testTenItemsAt45msPerBreakDropInsertedMarkers() {
        var time: TimeInterval = 0, lastPost: TimeInterval = 0
        var events: [(TimeInterval, () -> Void)] = []
        var posts: [String] = [], outcomes: [ListDeliveryMachine.Outcome] = []
        var editor = ""
        let m = ListDeliveryMachine(now: { time }, schedule: { events.append((time + $0, $1)) })
        m.deliver((1...10).map { "\($0). Alpha" }.joined(separator: "\n"), env: .init(worker: { request, done in
            let respond = { done(.init(request: request, same: true, value: editor, completed: time)) }
            if request.kind == .read, time < lastPost + 0.045 { events.append((lastPost + 0.045, respond)) }
            else { respond() }
        }, guardTarget: { true }, post: { text in
            posts.append(text); lastPost = time; editor += text
            if posts.count < 10 { editor += "\(posts.count + 1). " }
            return .posted
        })) { outcomes.append($0) }
        for _ in 0..<1000 {
            if !outcomes.isEmpty || events.isEmpty { break }
            events.sort { $0.0 < $1.0 }; let event = events.removeFirst(); time = event.0; event.1()
        }
        XCTAssertEqual(posts.count, 10); XCTAssertEqual(posts.dropFirst(), Array(repeating: "Alpha\n", count: 8) + ["Alpha"])
        XCTAssertEqual(outcomes, [.posted])
    }
    func testDrainThenCancelledDrainAllowsNewDelivery() {
        let h = Harness(); h.firstPost(); h.machine.drain()
        h.start("Alpha")
        XCTAssertEqual(h.posts, ["1. Alpha\n", "Alpha"])
        XCTAssertEqual(h.outcomes.last, .posted)
    }
    func testGateAdmissionIsRecheckedAfterDrainCancellation() {
        var allowed = false
        let m = ListDeliveryMachine(permitsNewDelivery: { allowed })
        var outcomes: [ListDeliveryMachine.Outcome] = []
        let env = ListDeliveryMachine.Environment(worker: { _, _ in XCTFail() }, guardTarget: { true }, post: { _ in .posted })
        m.deliver("Alpha", env: env) { outcomes.append($0) }
        allowed = true
        m.deliver("Alpha", env: env) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.refused, .posted])
    }
    func testStartCapturesEnvironmentOnlyWhenDequeued() {
        let h = Harness(); h.start()
        var epoch = 1, captured = 0
        h.machine.deliver("Alpha", env: .init(worker: { _, _ in XCTFail() },
            guardTarget: { captured == epoch }, post: { h.posts.append($0); return .posted },
            started: { captured = epoch })) { h.outcomes.append($0) }
        epoch = 2; h.expire()
        XCTAssertEqual(captured, 2); XCTAssertEqual(h.posts, ["Alpha"])
    }
    func testPostReadsClockOnceAtDeadlineBoundary() {
        var time: TimeInterval = 0, armed = false, reads = 0
        var pending: [(ListDeliveryMachine.Request, (ListDeliveryMachine.Reply) -> Void)] = []
        var timers: [() -> Void] = [], posts: [String] = []
        let m = ListDeliveryMachine(now: {
            if armed { reads += 1; return reads <= 3 ? 0.399 : 0.401 }
            return time
        }, schedule: { _, action in timers.append(action) })
        m.deliver("1. Alpha\n2. Beta", env: .init(worker: { pending.append(($0, $1)) }, guardTarget: { true },
            post: { posts.append($0); return .posted })) { _ in }
        func reply(_ value: String) {
            guard !pending.isEmpty else { XCTFail("Expected outstanding AX request"); return }
            let (r, done) = pending.removeFirst(); done(.init(request: r, same: true, value: value, completed: time))
        }
        reply(""); reply(""); reply("1. Alpha\n2. ")
        if pending.isEmpty { timers.last?(); reply("1. Alpha\n2. ") }
        time = 0.399; armed = true; reply("")
        XCTAssertEqual(reads, 3); XCTAssertEqual(posts, ["1. Alpha\n", "Beta"])
    }
    func testDiagnosticsContainVerdictsWithoutTranscript() {
        let h = Harness(); var lines: [String] = []
        h.machine.deliver("1. Alpha\n2. Beta", env: .init(worker: { h.pending.append(($0, $1)) },
            guardTarget: { true }, post: { h.posts.append($0); return .posted }, diagnostic: { lines.append($0) })) { _ in }
        h.reply(); h.reply(); h.reply(value: "1. Alpha\n"); h.reply()
        XCTAssertTrue(lines.contains { $0.contains("capture") }); XCTAssertTrue(lines.contains { $0.contains("plain_break") })
        XCTAssertTrue(lines.allSatisfy { !$0.contains("Alpha") && !$0.contains("Beta") })
    }
}
