import CoreGraphics
@testable import VoiceBar
import XCTest

final class HotkeyManagerTests: XCTestCase {
    func testConsumesMatchedKeyDownEvents() {
        XCTAssertTrue(
            shouldConsumeHotkeyEvent(
                hotkeyAction: .keyDown,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                keycode: 97
            )
        )
    }

    func testDoesNotConsumeNonMatchingEvents() {
        XCTAssertFalse(
            shouldConsumeHotkeyEvent(
                hotkeyAction: .ignore,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                keycode: 54
            )
        )
    }

    func testDefaultHotkeyConfigurationIncludesInternalF18Relay() {
        XCTAssertEqual(HotkeyManager.defaultTargetKeycodes, [79, 97, 177])
        XCTAssertFalse(HotkeyManager.defaultUsesModifierMode)
    }

    func testInternalF18RelayTriggersKeyDownInPlainMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 79,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyDown
        )
    }

    func testShiftF18RelayTriggersPasteLastTranscript() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 79,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .pasteLastTranscript
        )
    }

    func testCmdF6StandardFunctionKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyDown
        )
    }

    func testCmdF6MediaKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 177,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyDown
        )
    }

    func testCmdF6ReleaseTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testCmdF6MediaKeyReleaseTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 177,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testShiftF6TriggersPasteLastTranscript() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .pasteLastTranscript
        )
    }

    func testShiftF6TriggersPasteLastTranscriptInNonModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .pasteLastTranscript
        )
    }

    func testShiftF6ReleaseTriggersKeyUpToUnwindHoldInNonModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 97,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyUp
        )
    }

    func testShiftF6ReleaseTriggersKeyUpToUnwindHoldInModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 97,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testCmdShiftVIsIgnoredInNonModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 9,
                flags: [.maskCommand, .maskShift],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testModifierModeIgnoresNonTargetKeycodes() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 54,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testModifierModeIgnoresNonFlagsChangedEvents() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testModifierModeIgnoresTargetKeyWithoutCommandModifier() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true,
                currentModifierFlags: []
            ),
            .ignore
        )
    }

    func testModifierModeFallsBackToCurrentCommandFlagsWhenEventFlagsMissCommand() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true,
                currentModifierFlags: .maskCommand
            ),
            .keyDown
        )
    }

    func testPlainF6InNonModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyDown
        )
    }

    func testPlainF6InNonModifierModeTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 97,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyUp
        )
    }

    func testPlainVInNonModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 9,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testEscapeCancelsOnlyWhenGestureIsActive() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 53,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                gestureIsActive: true
            ),
            .cancel
        )
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 53,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                gestureIsActive: false
            ),
            .ignore
        )
    }

    func testNonModifierModeIgnoresAutorepeat() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: [],
                autorepeat: 1,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCmdF5InModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testF6WithoutCmdInModifierModeTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 97,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testDebounceIgnoresRapidRepeatedKeyDown() {
        let clock = DebounceClock(now: { 1.0 })
        var state = HotkeyDebounceState()

        XCTAssertFalse(
            shouldDebounceHotkeyAction(
                action: .keyDown,
                debounceState: &state,
                clock: clock
            )
        )
        XCTAssertTrue(
            shouldDebounceHotkeyAction(
                action: .keyDown,
                debounceState: &state,
                clock: DebounceClock(now: { 1.005 })
            )
        )
    }

    func testDebounceAllowsFastHumanDoubleTapCadence() {
        var state = HotkeyDebounceState(lastProcessedKeyDownTime: 1.0)

        XCTAssertFalse(
            shouldDebounceHotkeyAction(
                action: .keyDown,
                debounceState: &state,
                clock: DebounceClock(now: { 1.03 })
            )
        )
    }

    func testDebounceAllowsFastSecondPressAfterCooldown() {
        var state = HotkeyDebounceState(lastProcessedKeyDownTime: 1.0)

        XCTAssertFalse(
            shouldDebounceHotkeyAction(
                action: .keyDown,
                debounceState: &state,
                clock: DebounceClock(now: { 1.08 })
            )
        )
    }

    func testGestureShowsPressingPreviewBeforeHoldStartsRecording() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()

        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(phases, [.pressing])
    }

    func testGestureKeepsQuickTapOpenForDoubleTapWindow() {
        let gesture = GestureStateMachine()
        var holdEndCount = 0
        var singleTapCount = 0
        var doubleTapCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onSingleTap = { singleTapCount += 1 }
        gesture.onDoubleTap = { doubleTapCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()

        XCTAssertEqual(holdEndCount, 0)
        XCTAssertEqual(singleTapCount, 0)
        XCTAssertEqual(doubleTapCount, 0)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap])
    }

    func testGestureDoubleTapLocksActiveRecordingWithoutStopping() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var doubleTapCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onDoubleTap = { doubleTapCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()
        gesture.handleKeyDown()
        gesture.handleKeyUp()

        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdEndCount, 0)
        XCTAssertEqual(doubleTapCount, 1)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap, .holding])
    }

    func testGestureReleaseAfterHoldStopsImmediatelyWithoutWaitingForDoubleTap() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        gesture.handleKeyUp()

        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdEndCount, 1)
        XCTAssertEqual(phases, [.pressing, .holding, .idle])
        gesture.reset()
    }

    func testExpiredDoubleTapWindowTreatsNextKeyDownAsFreshPress() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var doubleTapCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onDoubleTap = { doubleTapCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()
        Thread.sleep(forTimeInterval: Double(GestureStateMachine.doubleTapWindowMs + 100) / 1000)
        gesture.handleKeyDown()

        XCTAssertEqual(gesture.state, .pressing)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(doubleTapCount, 0)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap, .idle, .pressing])
        gesture.reset()
    }

    func testSecondTapAfterFourHundredMillisecondsStartsFreshPress() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var doubleTapCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onDoubleTap = { doubleTapCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()
        Thread.sleep(forTimeInterval: 0.45)
        gesture.handleKeyDown()

        XCTAssertEqual(gesture.state, .pressing)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(doubleTapCount, 0)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap, .idle, .pressing])
        gesture.reset()
    }

    func testGestureCancelClearsPendingTapWithoutStartingOrStopping() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var cancelCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onCancel = { cancelCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()
        gesture.cancel()

        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(holdStartCount, 0)
        XCTAssertEqual(holdEndCount, 0)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap, .idle])
    }

    func testGestureCancelStopsLockedRecordingWithoutTranscribing() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var cancelCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onCancel = { cancelCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()
        gesture.handleKeyUp()
        gesture.handleKeyDown()
        gesture.handleKeyUp()
        gesture.cancel()

        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdEndCount, 0)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(phases, [.pressing, .awaitingSecondTap, .holding, .idle])
    }

    func testHotkeyPermissionStatusRequiresBothListenEventAndAccessibility() {
        XCTAssertEqual(
            HotkeyPermissionStatus(listenEventGranted: false, accessibilityGranted: false).missingPermissions,
            [.inputMonitoring, .accessibility]
        )
        XCTAssertEqual(
            HotkeyPermissionStatus(listenEventGranted: true, accessibilityGranted: false).missingPermissions,
            [.accessibility]
        )
    }
}
