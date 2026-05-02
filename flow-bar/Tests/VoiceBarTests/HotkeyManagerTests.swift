import CoreGraphics
@testable import VoiceBar
import XCTest

final class HotkeyManagerTests: XCTestCase {
    func testConsumesMatchedKeyDownEvents() {
        XCTAssertTrue(
            shouldConsumeHotkeyEvent(
                hotkeyAction: .keyDown,
                targetKeycodes: [97, 177],
                keycode: 97
            )
        )
    }

    func testDoesNotConsumeNonMatchingEvents() {
        XCTAssertFalse(
            shouldConsumeHotkeyEvent(
                hotkeyAction: .ignore,
                targetKeycodes: [97, 177],
                keycode: 54
            )
        )
    }

    func testDefaultHotkeyConfigurationUsesPlainF6() {
        XCTAssertEqual(HotkeyManager.defaultTargetKeycodes, [97, 177])
        XCTAssertFalse(HotkeyManager.defaultUsesModifierMode)
    }

    func testCmdF6StandardFunctionKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
                useModifierMode: false
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                targetKeycodes: [97, 177],
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
                clock: DebounceClock(now: { 1.02 })
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

    func testGestureStartsRecordingImmediatelyOnKeyDown() {
        let gesture = GestureStateMachine()
        var holdStartCount = 0
        var phases: [HotkeyPhase] = []
        gesture.onHoldStart = { holdStartCount += 1 }
        gesture.onPreviewPhaseChange = { phases.append($0) }

        gesture.handleKeyDown()

        XCTAssertEqual(holdStartCount, 1)
        XCTAssertEqual(phases, [.holding])
    }

    func testGestureStopsRecordingOnKeyUpWithoutWaitingForDoubleTap() {
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

        XCTAssertEqual(holdEndCount, 1)
        XCTAssertEqual(singleTapCount, 0)
        XCTAssertEqual(doubleTapCount, 0)
        XCTAssertEqual(phases, [.holding, .idle])
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
