import CoreGraphics
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// L105 (GO-1126 W1 slice B): rebinding the dictation key and the mouse side buttons changes only which events reach
/// the unchanged gesture machine.
final class HotkeyBindingsTests: XCTestCase {
    /// The default bindings ARE today's wiring: an unconfigured manager and one given the defaults match the same
    /// keys and buttons, so nobody who never opens the picker sees a change.
    func testDefaultsAreTodaysWiring() {
        let bindings = VoiceBarHotkeyBindings.defaults
        XCTAssertEqual(bindings.keycodes, HotkeyManager.defaultTargetKeycodes)
        XCTAssertEqual(bindings.dictationMouseButtons, HotkeyManager.defaultTargetMouseButtons)
        XCTAssertEqual(bindings.returnMouseButtons, HotkeyManager.defaultEnterMouseButtons)
        let manager = HotkeyManager(gesture: GestureStateMachine())
        let before = manager.matchSetsForTesting
        manager.apply(bindings)
        let after = manager.matchSetsForTesting
        XCTAssertEqual(before.keycodes, after.keycodes)
        XCTAssertEqual(before.mouse, after.mouse)
        XCTAssertEqual(before.enter, after.enter)
    }

    func testAnotherKeyReplacesF5AndTheRelay() {
        let manager = HotkeyManager(gesture: GestureStateMachine())
        manager.apply(VoiceBarHotkeyBindings(key: .f6))
        XCTAssertEqual(manager.matchSetsForTesting.keycodes, [97], "F6 only; F5 and the F18 relay stop matching")
        XCTAssertEqual(hotkeyAction(type: .keyDown, keycode: 97, flags: [], autorepeat: 0,
                                    targetKeycodes: manager.matchSetsForTesting.keycodes, useModifierMode: false,
                                    currentModifierFlags: []), .keyDown)
        XCTAssertEqual(hotkeyAction(type: .keyDown, keycode: 96, flags: [], autorepeat: 0,
                                    targetKeycodes: manager.matchSetsForTesting.keycodes, useModifierMode: false,
                                    currentModifierFlags: []), .ignore, "F5 passes through to the app")
        XCTAssertEqual(hotkeyAction(type: .keyDown, keycode: 97, flags: .maskShift, autorepeat: 0,
                                    targetKeycodes: manager.matchSetsForTesting.keycodes, useModifierMode: false,
                                    currentModifierFlags: .maskShift), .pasteLastTranscript,
                       "Shift+key re-paste follows the chosen key")
    }

    func testMouseRolesSwapAndClear() {
        let swapped = VoiceBarHotkeyBindings(forward: .returnKey, back: .dictation)
        XCTAssertEqual(swapped.dictationMouseButtons, [3])
        XCTAssertEqual(swapped.returnMouseButtons, [4, 5])
        XCTAssertEqual(mouseHotkeyAction(type: .otherMouseDown, buttonNumber: 3,
                                         targetMouseButtons: swapped.dictationMouseButtons,
                                         enterMouseButtons: swapped.returnMouseButtons), .keyDown)
        XCTAssertEqual(mouseHotkeyAction(type: .otherMouseDown, buttonNumber: 4,
                                         targetMouseButtons: swapped.dictationMouseButtons,
                                         enterMouseButtons: swapped.returnMouseButtons), .sendEnter)
        let none = VoiceBarHotkeyBindings(forward: .nothing, back: .nothing)
        XCTAssertTrue(none.dictationMouseButtons.isEmpty)
        XCTAssertTrue(none.returnMouseButtons.isEmpty)
        XCTAssertEqual(mouseHotkeyAction(type: .otherMouseDown, buttonNumber: 4,
                                         targetMouseButtons: none.dictationMouseButtons,
                                         enterMouseButtons: none.returnMouseButtons), .ignore,
                       "a button set to Nothing reaches the app")
    }

    func testF18RelayIsNeverOffered() {
        XCTAssertFalse(VoiceBarHotkeyBindings.Key.allCases.contains { $0.keycode == VoiceBarHotkeyBindings.relayKeycode })
        XCTAssertEqual(Set(VoiceBarHotkeyBindings.Key.allCases.map(\.keycode)).count, VoiceBarHotkeyBindings.Key.allCases.count)
    }

    func testLabelsFollowTheKey() {
        let bindings = VoiceBarHotkeyBindings(key: .f13)
        XCTAssertEqual(bindings.keyLabel, "F13")
        XCTAssertEqual(bindings.repasteLabel, "Shift+F13")
        XCTAssertEqual(bindings.speakSelectionLabel, "Option+F13")
        XCTAssertEqual(bindings.roleTitle(.dictation), "Like F13")
        XCTAssertEqual(VoiceBarHotkeyBindings.defaults.repasteLabel, VoiceBarHotkeyContract.repasteShortcutLabel)
        XCTAssertEqual(VoiceBarHotkeyBindings.defaults.speakSelectionLabel, VoiceBarHotkeyContract.speakSelectionShortcutLabel)
    }

    func testPersistenceRoundTripsAndDefaultsLeaveNothingSaved() throws {
        let suite = "voicebar.tests.hotkey-bindings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VoiceBarHotkeyBindings.load(from: defaults), .defaults)
        let custom = VoiceBarHotkeyBindings(key: .f9, forward: .nothing, back: .dictation)
        custom.save(to: defaults)
        XCTAssertEqual(VoiceBarHotkeyBindings.load(from: defaults), custom)
        VoiceBarHotkeyBindings.defaults.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: VoiceBarHotkeyBindings.defaultsKey))
        defaults.set(Data("not json".utf8), forKey: VoiceBarHotkeyBindings.defaultsKey)
        XCTAssertEqual(VoiceBarHotkeyBindings.load(from: defaults), .defaults, "unreadable data falls back to defaults")
    }
}
