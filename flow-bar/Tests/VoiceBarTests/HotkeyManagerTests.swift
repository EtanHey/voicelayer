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
}
