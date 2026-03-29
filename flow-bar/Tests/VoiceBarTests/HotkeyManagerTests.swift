import CoreGraphics
@testable import VoiceBar
import XCTest

final class HotkeyManagerTests: XCTestCase {
    func testCmdF5StandardFunctionKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .keyDown
        )
    }

    func testCmdF5MediaKeyInModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 176,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .keyDown
        )
    }

    func testCmdF5ReleaseTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 96,
                flags: [],
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testCmdF5MediaKeyReleaseTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 176,
                flags: [],
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .keyUp
        )
    }

    func testModifierModeIgnoresNonTargetKeycodes() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 54,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testModifierModeIgnoresNonFlagsChangedEvents() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testPlainF5InNonModifierModeTriggersKeyDown() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: [],
                autorepeat: 0,
                targetKeycodes: [96, 176],
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
                targetKeycodes: [96, 176],
                useModifierMode: false
            ),
            .keyUp
        )
    }

    func testNonModifierModeIgnoresAutorepeat() {
        XCTAssertEqual(
            hotkeyAction(
                type: .keyDown,
                keycode: 96,
                flags: [],
                autorepeat: 1,
                targetKeycodes: [96, 176],
                useModifierMode: false
            ),
            .ignore
        )
    }

    func testCmdF6InModifierModeIsIgnored() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 97,
                flags: .maskCommand,
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .ignore
        )
    }

    func testF5WithoutCmdInModifierModeTriggersKeyUp() {
        XCTAssertEqual(
            hotkeyAction(
                type: .flagsChanged,
                keycode: 96,
                flags: [],
                autorepeat: 0,
                targetKeycodes: [96, 176],
                useModifierMode: true
            ),
            .keyUp
        )
    }
}
