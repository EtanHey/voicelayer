import CoreGraphics
import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class HotkeyTapThreadTests: XCTestCase {
    private func context(gesture: GestureStateMachine = GestureStateMachine(),
                         returnPoster: HotkeyReturnKeyPoster = HotkeyReturnKeyPoster(post: { _ in }),
                         action: @escaping () -> Void = {}) -> TapContext {
        TapContext(gesture: gesture,
                   keycodes: HotkeyManager.defaultTargetKeycodes,
                   mouseButtons: HotkeyManager.defaultTargetMouseButtons,
                   enterMouseButtons: HotkeyManager.defaultEnterMouseButtons,
                   modifierMode: false,
                   onKeyDown: action, onKeyUp: action, onMouseDown: action, onMouseUp: action,
                   onCancel: action, onPasteLastTranscript: action, onSpeakSelection: action,
                   shouldHandleEscape: { false }, returnPoster: returnPoster)
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
            let warmup = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            _ = self.invoke(ctx, type: .keyDown, event: warmup)
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
        XCTAssertEqual(recovery.disabled(by: .tapDisabledByTimeout, now: 3).delay, 30)
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
        XCTAssertEqual(delays, [1, 2, 4, 30, 30])
        XCTAssertEqual(ctx.recovery.timeoutCount, 3)
        XCTAssertEqual(ctx.recovery.userInputCount, 2)
    }
}

extension HotkeyTapThreadTests {
    func testPendingPressMatchesThePriorClassifierWhileMainIsBlocked() throws {
        let runner = HotkeyTapRunLoop()
        _ = runner.start(install: { _ in }, cleanup: { _ in })
        defer { runner.stop() }
        typealias Input = (CGEventType, CGKeyCode, CGEventFlags, Int64)
        var cases: [[Input]] = []
        for key: CGKeyCode in [79, 96] {
            cases += [
                [(.keyDown, key, [], 0), (.keyDown, key, [], 1), (.keyUp, key, .maskCommand, 0)],
                [(.keyDown, key, [], 0), (.keyDown, 53, [], 0), (.keyUp, key, [], 0)],
                [(.keyDown, key, .maskCommand, 0), (.keyUp, key, .maskCommand, 0)],
                [(.keyDown, key, .maskControl, 0), (.keyUp, key, .maskControl, 0)],
                [(.keyDown, key, .maskAlternate, 0), (.keyDown, key, .maskAlternate, 1), (.keyUp, key, [], 0)],
                [(.keyDown, key, .maskShift, 0), (.keyDown, key, .maskShift, 1), (.keyUp, key, [], 0)],
            ]
        }
        let inputs = try cases.map { sequence in
            try sequence.map { type, key, flags, repeatValue -> (Input, CGEvent) in
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown))
                event.flags = flags
                event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatValue)
                return ((type, key, flags, repeatValue), event)
            }
        }
        let contexts = inputs.map { _ in context() }
        let complete = DispatchSemaphore(value: 0)
        var actual: [Bool] = []
        var prior: [Bool] = []
        runner.perform {
            Thread.sleep(forTimeInterval: 0.05)
            for (ctx, sequence) in zip(contexts, inputs) {
                XCTAssertEqual(ctx.activity.value, 0, "main has not published a gesture yet")
                var active = false
                var state = HotkeySequenceState()
                for ((type, key, flags, repeatValue), event) in sequence {
                    let action = sequenceAwareHotkeyAction(type: type, keycode: Int64(key), flags: flags,
                        autorepeat: repeatValue, targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                        useModifierMode: false, currentModifierFlags: flags, gestureIsActive: active,
                        cancellationIsActive: active, sequenceState: &state)
                    prior.append(shouldConsumeHotkeyEvent(hotkeyAction: action,
                        targetKeycodes: HotkeyManager.defaultTargetKeycodes, keycode: Int64(key)))
                    actual.append(self.invoke(ctx, type: type, event: event))
                    if action == .keyDown { active = true }
                    if action == .keyUp || action == .cancel { active = false }
                }
            }
            complete.signal()
        }
        Thread.sleep(forTimeInterval: 2)
        guard complete.wait(timeout: .now()) == .success else { XCTFail("callback blocked on main"); return }
        XCTAssertEqual(actual, prior)
        XCTAssertEqual(actual.count, 32)
    }

    func testPendingMousePressOwnsEscapeBeforeMainRuns() throws {
        let ctx = context()
        let down = try XCTUnwrap(CGEvent(source: nil))
        down.type = .otherMouseDown
        down.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        XCTAssertEqual(down.getIntegerValueField(.mouseEventButtonNumber), 4)
        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        XCTAssertTrue(invoke(ctx, type: .otherMouseDown, event: down))
        XCTAssertEqual(ctx.activity.value, 0)
        XCTAssertTrue(invoke(ctx, type: .keyDown, event: escape))
        XCTAssertTrue(invoke(ctx, type: .otherMouseUp, event: down))
        XCTAssertFalse(ctx.hasPendingPress)
    }

    func testHardwareCommandFallbackIsQueriedOnlyForMissingModifierDown() throws {
        let ctx = TapContext(gesture: GestureStateMachine(), keycodes: [96], mouseButtons: [],
            enterMouseButtons: [], modifierMode: true, onKeyDown: {}, onKeyUp: {},
            onMouseDown: {}, onMouseUp: {}, onCancel: {}, onPasteLastTranscript: {},
            shouldHandleEscape: { false })
        var reads = 0
        ctx.readModifierFlags = { reads += 1; return .maskCommand }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: true))
        event.flags = []
        XCTAssertTrue(invoke(ctx, type: .keyDown, event: event))
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(invoke(ctx, type: .keyUp, event: event))
        event.flags = .maskCommand
        XCTAssertTrue(invoke(ctx, type: .keyDown, event: event))
        XCTAssertEqual(reads, 1)
    }

    func testAppDelegatePublishesTheSharedEscapePredicate() {
        let app = AppDelegate()
        app.configureHotkeyCallbacksForTesting()
        let manager = app.makeHotkeyManager()
        for mode: VoiceMode in [.recording, .transcribing, .speaking, .idle, .error, .disconnected] {
            app.voiceState.mode = mode
            XCTAssertEqual(manager.activity.value & 2 != 0, app.commandRouter.shouldHandleEscape)
            XCTAssertEqual(app.commandRouter.shouldHandleEscape, app.voiceState.shouldHandleHotkeyEscape)
        }
    }

    func testTapCreationSourceAndCleanupRunOnOwningThreadWithoutGlobalInput() throws {
        let cleaned = expectation(description: "tap source invalidated on its thread")
        var made: CFMachPort?
        let driver = HotkeyTapDriver(create: { mask, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(mask & CGEventMask(1 << CGEventType.mouseMoved.rawValue), 0)
            var context = CFMachPortContext()
            let port = CFMachPortCreate(nil, { _, _, _, _ in }, &context, nil)
            made = port
            return port
        }, enable: { port, enabled in
            XCTAssertFalse(Thread.isMainThread)
            if enabled {
                let source = CFMachPortCreateRunLoopSource(nil, port, 0)!
                XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetCurrent(), source, .commonModes))
            }
        },
           isEnabled: { _ in true }, invalidate: { port in
            XCTAssertFalse(Thread.isMainThread)
            CFMachPortInvalidate(port)
            cleaned.fulfill()
        })
        let manager = HotkeyManager(gesture: GestureStateMachine(), driver: driver,
            permissionProvider: { HotkeyPermissionStatus(listenEventGranted: true, accessibilityGranted: true) })
        XCTAssertTrue(manager.start())
        let port = try XCTUnwrap(made)
        XCTAssertTrue(CFMachPortIsValid(port))
        manager.stop()
        wait(for: [cleaned], timeout: 2)
        XCTAssertFalse(CFMachPortIsValid(port))
    }

    func testExhaustedBudgetSchedulesCoolOffAndStaleAttemptsCannotReenable() throws {
        let ctx = context()
        var tasks: [() -> Void] = []
        var delays: [TimeInterval] = []
        var enables = 0
        ctx.reenableTap = { enables += 1 }
        ctx.scheduleRecovery = { delay, work in delays.append(delay); tasks.append(work) }
        let event = try XCTUnwrap(CGEvent(source: nil))
        for _ in 0..<4 { _ = invoke(ctx, type: .tapDisabledByTimeout, event: event) }
        XCTAssertEqual(delays, [1, 2, 4, 30])
        tasks.forEach { $0() }
        XCTAssertEqual(enables, 1, "the cool-off attempt survives exhaustion; earlier attempts are obsolete")
        ctx.invalidate()
        tasks.last?()
        XCTAssertEqual(enables, 1, "stop fences even the cool-off attempt")
    }

    func testRecoveryTimerRunsWhileMainIsBlocked() {
        let runner = HotkeyTapRunLoop()
        let recovered = DispatchSemaphore(value: 0)
        _ = runner.start(install: { loop in
            HotkeyTapRunLoop.schedule(on: loop, after: 0.05) {
                XCTAssertFalse(Thread.isMainThread)
                recovered.signal()
            }
        }, cleanup: { _ in })
        defer { runner.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recovered.wait(timeout: .now()), .success)
    }

    func testReturnPairsRunBeforeMainUnblocksAndStaleRequestsAreDropped() {
        let queue = DispatchQueue(label: "L8.Return.test")
        let pairs = DispatchSemaphore(value: 0)
        var events: [Bool] = []
        let poster = HotkeyReturnKeyPoster(queue: queue, now: { 1_000_000_000 }, post: { down in
            XCTAssertFalse(Thread.isMainThread)
            events.append(down)
            if events.count == 4 { pairs.signal() }
        })
        poster.enqueue(timestamp: 700_000_000, isCurrent: { true }) // stale: 300ms
        poster.enqueue(timestamp: 1_000_000_001, isCurrent: { true }) // future timestamp
        poster.enqueue(timestamp: 1_000_000_000, isCurrent: { false }) // stopped listener
        let ctx = context(returnPoster: poster)
        let mouse = CGEvent(source: nil)!
        mouse.type = .otherMouseDown
        mouse.timestamp = 1_000_000_000
        mouse.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertTrue(invoke(ctx, type: .otherMouseDown, event: mouse))
        poster.enqueue(timestamp: 1_000_000_000, isCurrent: { true })
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(pairs.wait(timeout: .now()), .success)
        queue.sync { XCTAssertEqual(events, [true, false, true, false]) }
    }
}
