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

    func testStopEndsTheRunningListener() {
        let taps = Taps()
        let lifecycle = lifecycle([true], taps: taps)
        _ = lifecycle.start()
        lifecycle.stop()
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertEqual(taps.live, 0)
    }
}
