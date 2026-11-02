import CoreGraphics
import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class HotkeyTapThreadTests: XCTestCase {
    private func context(gesture: GestureStateMachine = GestureStateMachine(),
                         action: @escaping () -> Void = {}) -> TapContext {
        TapContext(gesture: gesture,
                   keycodes: HotkeyManager.defaultTargetKeycodes,
                   mouseButtons: HotkeyManager.defaultTargetMouseButtons,
                   enterMouseButtons: HotkeyManager.defaultEnterMouseButtons,
                   modifierMode: false,
                   onKeyDown: action, onKeyUp: action, onMouseDown: action, onMouseUp: action,
                   onCancel: action, onPasteLastTranscript: action, onSpeakSelection: action,
                   shouldHandleEscape: { false }, onSendEnter: action)
    }

    private func invoke(_ ctx: TapContext, type: CGEventType, event: CGEvent) -> Bool {
        let pointer = Unmanaged.passUnretained(ctx).toOpaque()
        return hotkeyCallback(OpaquePointer(pointer), type: type, event: event, userInfo: pointer) == nil
    }

    /// Runs the real C callback on the production run-loop thread while main is
    /// asleep for two seconds. No event is posted; Return and audio are replaced.
    func testCallbackReturnsWithinFiveMillisecondsWhileMainIsBlockedForTwoSeconds() throws {
        XCTAssertTrue(Thread.isMainThread)
        let runner = HotkeyTapRunLoop()
        XCTAssertTrue(runner.start(install: { _ in }, cleanup: { _ in }))
        defer { runner.stop() }
        var delivered = 0
        let ctx = context { XCTAssertTrue(Thread.isMainThread); delivered += 1 }
        ctx.activity.setCancellationActive(true)
        var samples: [(CGEventType, CGEvent, Bool)] = []
        for key: CGKeyCode in [79, 96] {
            for flags: CGEventFlags in [[], .maskShift, .maskAlternate] {
                for down in [true, false] {
                    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
                    event.flags = flags
                    samples.append((down ? .keyDown : .keyUp, event, true))
                }
            }
        }
        for button: Int64 in [2, 3, 4, 5] {
            for type: CGEventType in [.otherMouseDown, .otherMouseUp] {
                let event = try XCTUnwrap(CGEvent(source: nil))
                event.type = type
                event.setIntegerValueField(.mouseEventButtonNumber, value: button)
                samples.append((type, event, button != 2))
            }
        }
        for key: CGKeyCode in [0, 53] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
            samples.append((.keyDown, event, key == 53))
        }
        let completed = DispatchSemaphore(value: 0)
        var durations: [Double] = []
        var consumption: [Bool] = []
        var onMain = true
        let input = samples
        runner.perform {
            // Main will be sleeping before this begins; this is NOT callback time.
            Thread.sleep(forTimeInterval: 0.05)
            onMain = Thread.isMainThread
            for (type, event, _) in input {
                let start = DispatchTime.now().uptimeNanoseconds
                consumption.append(self.invoke(ctx, type: type, event: event))
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            completed.signal()
        }
        Thread.sleep(forTimeInterval: 2)
        guard completed.wait(timeout: .now()) == .success else {
            // Synchronize before inspecting any worker-owned results on failure.
            _ = completed.wait(timeout: .now() + 2)
            XCTFail("callback did not finish during the two-second main-thread block")
            return
        }
        XCTAssertFalse(onMain)
        XCTAssertEqual(delivered, 0, "side effects must wait asynchronously for main")
        XCTAssertEqual(consumption, samples.map { $0.2 })
        XCTAssertEqual(durations.count, samples.count)
        XCTAssertLessThan(durations.max() ?? .infinity, 5, "callback samples (ms): \(durations)")
        print("L8 callback mainBlocked=2s samples=\(durations.count) maxMs=\(durations.max() ?? .infinity)")
        let drained = expectation(description: "FIFO main actions drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertGreaterThan(delivered, 0)
    }

    func testStoppedContextPassesInputAndDropsAlreadyQueuedActions() throws {
        var delivered = 0
        let ctx = context { delivered += 1 }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: true))
        XCTAssertTrue(invoke(ctx, type: .keyDown, event: event))
        ctx.invalidate()
        XCTAssertFalse(invoke(ctx, type: .keyDown, event: event))
        let drained = expectation(description: "queued stale actions dropped")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delivered, 0)
    }

    func testEscapeEligibilityPublishesSynchronouslyForEveryVoiceMode() throws {
        let gesture = GestureStateMachine()
        let ctx = context(gesture: gesture)
        let voice = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        voice.onHotkeyCancellationChange = { gesture.activity.setCancellationActive($0) }
        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        for mode: VoiceMode in [.recording, .transcribing, .speaking, .idle, .error, .disconnected] {
            voice.mode = mode
            XCTAssertEqual(invoke(ctx, type: .keyDown, event: escape),
                           [.recording, .transcribing, .speaking].contains(mode), "\(mode)")
        }
        gesture.handleKeyDown()
        XCTAssertTrue(invoke(ctx, type: .keyDown, event: escape))
        gesture.reset()
        XCTAssertFalse(invoke(ctx, type: .keyDown, event: escape))
    }

    func testOccasionalDisablesRestoreRecoveryBudgetWithoutLosingCounters() {
        var recovery = HotkeyTapRecovery()
        XCTAssertEqual(recovery.disabled(by: .tapDisabledByTimeout, now: 0).delay, 1)
        XCTAssertEqual(recovery.disabled(by: .tapDisabledByUserInput, now: 1).delay, 2)
        XCTAssertEqual(recovery.disabled(by: .tapDisabledByTimeout, now: 2).delay, 4)
        XCTAssertNil(recovery.disabled(by: .tapDisabledByTimeout, now: 3).delay)
        XCTAssertEqual(recovery.disabled(by: .tapDisabledByUserInput, now: 33).delay, 1)
        XCTAssertEqual(recovery.timeoutCount, 3)
        XCTAssertEqual(recovery.userInputCount, 2)
    }

    func testBothDisableReasonsHaveCountersAndBoundedBackoff() throws {
        let ctx = context()
        var delays: [TimeInterval] = []
        ctx.scheduleRecovery = { delay, _ in delays.append(delay) }
        let event = try XCTUnwrap(CGEvent(source: nil))
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput,
                                 .tapDisabledByTimeout, .tapDisabledByUserInput, .tapDisabledByTimeout] {
            XCTAssertFalse(invoke(ctx, type: type, event: event))
        }
        XCTAssertEqual(delays, [1, 2, 4])
        XCTAssertEqual(ctx.recovery.timeoutCount, 3)
        XCTAssertEqual(ctx.recovery.userInputCount, 2)
    }
}
