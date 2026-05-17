import CoreGraphics
@testable import VoiceBar
import XCTest

final class HotkeyManagerTests: XCTestCase {
    func testConsumesMatchedKeyDownEvents() {
        XCTAssertTrue(
            shouldConsumeHotkeyEvent(
                hotkeyAction: .keyDown,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                keycode: 96
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
        XCTAssertEqual(HotkeyManager.defaultTargetKeycodes, [79, 96])
        XCTAssertEqual(HotkeyManager.defaultTargetMouseButtons, [4, 5])
        XCTAssertEqual(HotkeyManager.defaultEnterMouseButtons, [3])
        XCTAssertFalse(HotkeyManager.defaultUsesModifierMode)
    }

    func testMouseButtonFiveTriggersHotkeyDown() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseDown,
                buttonNumber: 4,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons
            ),
            .keyDown
        )
    }

    func testMouseButtonFiveReleaseTriggersHotkeyUp() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseUp,
                buttonNumber: 4,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons
            ),
            .keyUp
        )
    }

    func testHidUsageNumberedMouseButtonFiveAlsoTriggersHotkey() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseDown,
                buttonNumber: 5,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons
            ),
            .keyDown
        )
    }

    func testOtherMouseButtonsAreIgnored() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseDown,
                buttonNumber: 2,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons,
                enterMouseButtons: HotkeyManager.defaultEnterMouseButtons
            ),
            .ignore
        )
    }

    func testMouseButtonFourSendsEnterOnPress() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseDown,
                buttonNumber: 3,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons,
                enterMouseButtons: HotkeyManager.defaultEnterMouseButtons
            ),
            .sendEnter
        )
    }

    func testMouseButtonFourReleaseIsConsumed() {
        XCTAssertEqual(
            mouseHotkeyAction(
                type: .otherMouseUp,
                buttonNumber: 3,
                targetMouseButtons: HotkeyManager.defaultTargetMouseButtons,
                enterMouseButtons: HotkeyManager.defaultEnterMouseButtons
            ),
            .consume
        )
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

    func testCmdF5StandardFunctionKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyDown
        )
    }

    func testCmdF6MediaKeyInModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 177,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testCmdF5ReleaseTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testCmdF6MediaKeyReleaseInModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 177,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testShiftF5TriggersPasteLastTranscript() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .pasteLastTranscript
        )
    }

    func testShiftF5TriggersPasteLastTranscriptInNonModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .pasteLastTranscript
        )
    }

    func testShiftF5ReleaseTriggersKeyUpToUnwindHoldInNonModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskShift,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyUp
        )
    }

    func testShiftF5ReleaseTriggersKeyUpToUnwindHoldInModifierMode() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
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
                keycode: 96,
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
                keycode: 96,
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
                keycode: 96,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true,
                currentModifierFlags: .maskCommand
            ),
            .keyDown
        )
    }

    func testPlainF5InNonModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .keyDown
        )
    }

    func testPlainF5InNonModifierModeTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
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

    // MARK: - Plain-mode system shortcuts must pass through
    //
    // In plain mode the hotkey is the bare F5 (or F18 from the hidutil relay),
    // plus the Shift+F5 re-paste chord. Any other modifier+F5 combo (Cmd+F5
    // toggles VoiceOver, Ctrl+F5 toggles full keyboard access, Option+F5 is a
    // common user-defined chord) must NOT be consumed by VoiceBar's event tap;
    // returning .ignore lets the event reach the OS / focused app.

    func testCmdF5InPlainModeIsIgnoredSoVoiceOverShortcutPassesThrough() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCmdF5KeyUpInPlainModeIsIgnoredToKeepEventPairing() {
        // Both keyDown AND keyUp must be ignored. If VoiceBar's tap consumed
        // only the keyUp, the OS would see an unpaired keyDown for the
        // VoiceOver chord and could leave modifier state stuck. The niche
        // case of "plain F5 hold + Cmd added mid-hold" unwinds via the
        // gesture state machine's timeouts rather than this code path.
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCtrlF5KeyUpInPlainModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskControl,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testOptF5KeyUpInPlainModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskAlternate,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    // MARK: - Active-hold escape hatch for modified releases
    //
    // The plain-mode modifier guard returns .ignore so system chords pass
    // through, BUT when a VoiceBar gesture is already active and the user
    // happens to be holding a modifier on release, we still need .keyUp so
    // GestureStateMachine.handleKeyUp() can unwind the hold — otherwise the
    // recording stays open until manually cancelled.

    func testCmdF5KeyUpDuringActiveHoldStillUnwindsGesture() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                gestureIsActive: true
            ),
            .keyUp
        )
    }

    func testCtrlF5KeyUpDuringActiveHoldStillUnwindsGesture() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
                flags: .maskControl,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                gestureIsActive: true
            ),
            .keyUp
        )
    }

    func testCmdF5KeyDownDuringActiveHoldStillIgnoredForOSChord() {
        // keyDown is the chord-trigger; even with a stale active gesture
        // VoiceBar should not eat the system shortcut.
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                gestureIsActive: true
            ),
            .ignore
        )
    }

    func testCmdF18RelayInPlainModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 79,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCtrlF5InPlainModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskControl,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testOptF5InPlainModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskAlternate,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testEscapeCancelsWhenGestureOrVoiceBarSessionIsActive() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 53,
                flags: [],
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false,
                cancellationIsActive: true
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
                cancellationIsActive: false
            ),
            .ignore
        )
    }

    func testNonModifierModeIgnoresAutorepeat() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: [],
                autorepeat: 1,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCmdF6InModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: HotkeyManager.defaultTargetKeycodes,
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testF5WithoutCmdInModifierModeTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyUp,
                keycode: 96,
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

    func testMouseQuickClickLocksRecordingImmediately() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleMouseButtonDown()
        gesture.handleMouseButtonUp()

        XCTAssertEqual(gesture.state, .locked)
        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdEndCount, 0)
        XCTAssertEqual(phases, [.pressing, .holding])
        gesture.reset()
    }

    func testMouseHoldStillStopsOnRelease() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var holdEndCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onHoldEnd = { holdEndCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleMouseButtonDown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        gesture.handleMouseButtonUp()

        XCTAssertEqual(gesture.state, .idle)
        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(holdEndCount, 1)
        XCTAssertEqual(phases, [.pressing, .holding, .idle])
        gesture.reset()
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
