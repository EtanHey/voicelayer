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

    func testDefaultHotkeyConfigurationUsesCmdF6Keycodes() {
        XCTAssertEqual(HotkeyManager.defaultTargetKeycodes, [97, 177])
        XCTAssertTrue(HotkeyManager.defaultUsesModifierMode)
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

    func testCmdShiftVTriggersPasteLastTranscript() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 9,
                flags: [.maskCommand, .maskShift],
                autorepeat: 0,
                targetKeycodes: [97, 177],
                useModifierMode: true
            ),
            .pasteLastTranscript
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
                clock: DebounceClock(now: { 1.2 })
            )
        )
    }

    func testDebounceAllowsKeyDownAfterCooldown() {
        var state = HotkeyDebounceState(lastProcessedKeyDownTime: 1.0)

        XCTAssertFalse(
            shouldDebounceHotkeyAction(
                action: .keyDown,
                debounceState: &state,
                clock: DebounceClock(now: { 1.31 })
            )
        )
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
