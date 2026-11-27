@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// "Restart F5 listener": the start/stop lifecycle only. A fake listener stands in for the event tap, so no test
/// creates a real CGEventTap.
final class HotkeyListenerLifecycleTests: XCTestCase {
    private final class Taps {
        var live = 0
        var made: [FakeListener] = []
    }

    private final class FakeListener: HotkeyListening {
        let taps: Taps
        let startSucceeds: Bool
        let missingPermissions: [HotkeyPermission]
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var isEnabled = true
        private var tapped = false

        init(taps: Taps, startSucceeds: Bool, missing: [HotkeyPermission]) {
            self.taps = taps
            self.startSucceeds = startSucceeds
            missingPermissions = missing
        }

        func start() -> Bool {
            startCount += 1
            guard startSucceeds else { return false }
            tapped = true
            taps.live += 1
            return true
        }

        func stop() {
            stopCount += 1
            if tapped { taps.live -= 1 }
            tapped = false
        }
    }

    /// Each new listener takes the next scripted answer (true = the tap starts); the last one repeats.
    private func lifecycle(
        _ answers: [Bool],
        missing: [HotkeyPermission] = [.accessibility],
        taps: Taps
    ) -> HotkeyListenerLifecycle {
        HotkeyListenerLifecycle {
            let succeeds = answers[min(taps.made.count, answers.count - 1)]
            let listener = FakeListener(taps: taps, startSucceeds: succeeds, missing: succeeds ? [] : missing)
            taps.made.append(listener)
            return listener
        }
    }

    /// L105: a changed binding rebuilds the tap. The running tap is stopped before the new one starts (never two
    /// consumers), unlike Restart, which leaves a running tap alone.
    func testRebindReplacesTheRunningTapWithExactlyOne() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        XCTAssertEqual(lifecycle.start(), .started)
        var outcome: HotkeyListenerRestartOutcome?
        lifecycle.rebind(isRecording: false) { outcome = $0 }
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(taps.made.count, 2, "a fresh listener reads the new binding")
        XCTAssertEqual(taps.made[0].stopCount, 1, "the old tap is stopped")
        XCTAssertEqual(taps.live, 1, "exactly one live tap after a rebind")
    }

    /// Codex r1 on #980: the old tap's teardown runs on its own thread after `stop()` returns, and a callback already
    /// inside it can still consume an event. The new tap must not arm until that teardown has finished.
    private final class SlowTeardownListener: HotkeyListening {
        let taps: Taps
        var isEnabled = true
        let missingPermissions: [HotkeyPermission] = []
        var pendingTeardown: (() -> Void)?
        private(set) var consumedAfterStop = 0
        init(taps: Taps) { self.taps = taps }
        func start() -> Bool { taps.live += 1; return true }
        func stop() { stop(teardown: {}) }
        func stop(teardown: @escaping () -> Void) {
            isEnabled = false
            pendingTeardown = { [unowned self] in self.taps.live -= 1; teardown() }
        }
        /// An event already inside the old tap's callback when stop was requested.
        func deliverInFlightEvent() { if pendingTeardown != nil { consumedAfterStop += 1 } }
    }

    func testRebindArmsTheNewTapOnlyAfterTheOldTapsTeardown() {
        let taps = Taps()
        var made: [HotkeyListening] = []
        let first = SlowTeardownListener(taps: taps)
        let lifecycle = HotkeyListenerLifecycle {
            if made.isEmpty { made.append(first); return first }
            let fresh = FakeListener(taps: taps, startSucceeds: true, missing: [])
            made.append(fresh)
            return fresh
        }
        XCTAssertEqual(lifecycle.start(), .started)
        var outcome: HotkeyListenerRestartOutcome?
        lifecycle.rebind(isRecording: false) { outcome = $0 }
        first.deliverInFlightEvent()
        XCTAssertEqual(first.consumedAfterStop, 1, "fixture: the old tap is still consuming during its teardown")
        XCTAssertNil(outcome, "no new tap while the old one is still being torn down")
        XCTAssertEqual(made.count, 1, "the replacement is not even built yet")
        XCTAssertEqual(taps.live, 1)
        first.pendingTeardown?()
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(taps.live, 1, "never two consuming taps")
    }

    /// The real tap thread: `stop(teardown:)` reports only after the thread's cleanup (tap disable/invalidate) ran.
    func testTapRunLoopReportsTeardownAfterItsCleanup() {
        let runner = HotkeyTapRunLoop()
        let cleaned = Atomic()
        XCTAssertTrue(runner.start(install: { _ in }, cleanup: { _ in
            Thread.sleep(forTimeInterval: 0.2) // a deliberately slow cleanup
            cleaned.set()
        }))
        let reported = expectation(description: "teardown reported")
        runner.stop(teardown: {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(cleaned.isSet, "teardown is reported only after cleanup finished")
            reported.fulfill()
        })
        XCTAssertFalse(cleaned.isSet, "stop returns before the slow cleanup")
        wait(for: [reported], timeout: 3)
    }

    private final class Atomic: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testRebindIsRefusedWhileRecording() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        XCTAssertEqual(lifecycle.start(), .started)
        var outcome: HotkeyListenerRestartOutcome?
        lifecycle.rebind(isRecording: true) { outcome = $0 }
        XCTAssertEqual(outcome, .refusedWhileRecording)
        XCTAssertEqual(taps.made.count, 1)
        XCTAssertEqual(taps.made[0].stopCount, 0, "the recording keeps the key that ends it")
        XCTAssertEqual(taps.live, 1)
    }

    func testLaunchStartKeepsTheRunningListener() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        XCTAssertEqual(lifecycle.start(), .started)
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(taps.live, 1)
    }

    func testRestartWhileRunningStartsNoSecondTap() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        _ = lifecycle.start()
        XCTAssertEqual(lifecycle.restart(isRecording: false), .alreadyRunning)
        XCTAssertEqual(lifecycle.restart(isRecording: false), .alreadyRunning)
        XCTAssertEqual(taps.made.count, 1)
        XCTAssertEqual(taps.live, 1)
        XCTAssertEqual(taps.made[0].stopCount, 0, "a running listener is left alone")
    }

    /// Permissions granted after launch: the restart starts a fresh listener, and the failed one is gone.
    func testRestartAfterAFailedLaunchStartsTheListener() {
        let taps = Taps()
        let lifecycle = lifecycle([false, true], taps: taps)
        XCTAssertEqual(lifecycle.start(), .failed(missing: [.accessibility]))
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.restart(isRecording: false), .started)
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(taps.made.count, 2)
        XCTAssertEqual(taps.live, 1)
    }

    func testAFailedStartTearsDownItsHalfStartedListener() {
        let taps = Taps()
        let lifecycle = lifecycle([false], missing: [.inputMonitoring], taps: taps)
        XCTAssertEqual(lifecycle.start(), .failed(missing: [.inputMonitoring]))
        XCTAssertEqual(lifecycle.restart(isRecording: false), .failed(missing: [.inputMonitoring]))
        XCTAssertEqual(taps.made.map(\.stopCount), [1, 1], "each failed listener is stopped before it is dropped")
        XCTAssertEqual(taps.live, 0)
        XCTAssertFalse(lifecycle.isRunning)
    }

    func testRestartIsRefusedWhileRecording() {
        let taps = Taps()
        let lifecycle = lifecycle([false, true], taps: taps)
        _ = lifecycle.start()
        XCTAssertEqual(lifecycle.restart(isRecording: true), .refusedWhileRecording)
        XCTAssertEqual(taps.made.count, 1, "no listener is made while recording")
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.restart(isRecording: false), .started)
    }

    func testRestartRebuildsADisabledTapAndRefusesDuringRecording() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        _ = lifecycle.start()
        taps.made[0].isEnabled = false
        XCTAssertEqual(lifecycle.restart(isRecording: true), .refusedWhileRecording)
        XCTAssertEqual(taps.made.count, 1)
        XCTAssertEqual(lifecycle.restart(isRecording: false), .started)
        XCTAssertEqual(taps.made[0].stopCount, 1)
        XCTAssertEqual(taps.made.count, 2)
        XCTAssertEqual(taps.live, 1)
    }

    func testStopEndsTheRunningListener() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        _ = lifecycle.start()
        lifecycle.stop()
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(taps.live, 0)
    }
}
