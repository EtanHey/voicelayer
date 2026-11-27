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
        XCTAssertEqual(bindings.roleTitle(.dictation), "Dictation",
                       "a mouse button is a dictation button with its own gesture, not a copy of the key (Codex r1)")
        XCTAssertEqual(VoiceBarHotkeyBindings.defaults.repasteLabel, VoiceBarHotkeyContract.repasteShortcutLabel)
        XCTAssertEqual(VoiceBarHotkeyBindings.defaults.speakSelectionLabel, VoiceBarHotkeyContract.speakSelectionShortcutLabel)
    }

    /// The shortcut check names the bound key, and the F5-only 🎤 relay never blocks another key.
    func testShortcutCheckFollowsTheBoundKey() {
        XCTAssertEqual(SettingsShortcutCheck.message(hotkeyEnabled: true, missingPermissions: [], relayReady: true,
                                                     relaySummary: "ok"), SettingsShortcutCheck.readyMessage)
        XCTAssertEqual(SettingsShortcutCheck.message(hotkeyEnabled: true, missingPermissions: [], relayReady: false,
                                                     relaySummary: "Relay not installed", key: "F6"),
                       "Shortcut ready: F6 listener is active.")
        XCTAssertEqual(SettingsShortcutCheck.message(hotkeyEnabled: false, missingPermissions: [], relayReady: false,
                                                     relaySummary: "Relay not installed", key: "F6"),
                       "Shortcut needs attention: F6 listener unavailable.")
        XCTAssertEqual(SettingsShortcutCheck.message(hotkeyEnabled: true, missingPermissions: [], relayReady: false,
                                                     relaySummary: "Relay not installed"),
                       "Shortcut needs attention: Relay not installed.")
        XCTAssertTrue(SettingsShortcutCheck.feedback(message: "Shortcut ready: F6 listener is active.",
                                                     checkedAt: Date()).hasPrefix("Checked ✓"))
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

    // MARK: Codex r1 on #980

    /// (2) A replacement tap that fails to start is never saved: the previous bindings and listener come back and the
    /// picker gets the reason.
    @MainActor
    func testAFailedTapReplacementKeepsThePreviousBindingAndListener() throws {
        let suite = "voicebar.tests.hotkey-bindings.app.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        app.hotkeyBindingsStore = store
        let taps = ScriptedTaps(answers: [true, false, true])
        app.hotkeyListener = HotkeyListenerLifecycle { taps.make() }
        XCTAssertEqual(app.hotkeyListener.start(), .started)
        var failure: String?? = .none
        app.applyHotkeyBindings(VoiceBarHotkeyBindings(key: .f6)) { failure = .some($0) }
        let reason = try XCTUnwrap(failure ?? nil, "the caller hears that the switch failed")
        XCTAssertTrue(reason.contains("F5 stays"), reason)
        XCTAssertEqual(app.hotkeyBindings, .defaults, "the failed selection is not kept")
        XCTAssertNil(store.object(forKey: VoiceBarHotkeyBindings.defaultsKey), "nothing was saved")
        XCTAssertEqual(taps.made, 3, "old, failed replacement, restored listener")
        XCTAssertEqual(taps.live, 1, "the previous listener is running again")

        var success: String?? = .none
        let ok = ScriptedTaps(answers: [true, true])
        app.hotkeyListener = HotkeyListenerLifecycle { ok.make() }
        XCTAssertEqual(app.hotkeyListener.start(), .started)
        app.applyHotkeyBindings(VoiceBarHotkeyBindings(key: .f6)) { success = .some($0) }
        XCTAssertEqual(success, .some(nil))
        XCTAssertEqual(app.hotkeyBindings.key, .f6)
        XCTAssertEqual(VoiceBarHotkeyBindings.load(from: store).key, .f6, "saved only after the new tap is live")
    }

    private final class ScriptedTaps {
        private var answers: [Bool]
        private(set) var made = 0
        var live = 0
        init(answers: [Bool]) { self.answers = answers }
        func make() -> HotkeyListening {
            made += 1
            return Listener(owner: self, succeeds: answers.isEmpty ? true : answers.removeFirst())
        }
        final class Listener: HotkeyListening {
            unowned let owner: ScriptedTaps
            let succeeds: Bool
            private var tapped = false
            var isEnabled: Bool { tapped }
            var missingPermissions: [HotkeyPermission] { [] }
            init(owner: ScriptedTaps, succeeds: Bool) { self.owner = owner; self.succeeds = succeeds }
            func start() -> Bool { guard succeeds else { return false }; tapped = true; owner.live += 1; return true }
            func stop() { if tapped { owner.live -= 1 }; tapped = false }
        }
    }

    /// (3) One shared state: edits from two surfaces apply to the latest bindings, never to a stale per-surface copy.
    @MainActor
    func testEditsFromTwoSurfacesApplyToTheLatestBindings() {
        var applied: [VoiceBarHotkeyBindings] = []
        let model = HotkeyBindingsModel(bindings: .defaults, apply: { next, done in applied.append(next); done(nil) })
        let window = model, notch = model // both Settings surfaces read the app's one model
        window.update { $0.key = .f6 }
        notch.update { $0.key = .f7 }
        window.update { $0.back = .dictation }
        XCTAssertEqual(model.bindings, VoiceBarHotkeyBindings(key: .f7, forward: .dictation, back: .dictation))
        XCTAssertEqual(applied.last, model.bindings, "the window's mouse edit kept the notch's F7")
    }

    /// (2) and (5): a failed apply leaves the bindings and the key generation alone; a key change bumps it, a mouse
    /// role change does not.
    @MainActor
    func testTheModelChangesOnlyOnSuccessAndCountsKeyChanges() {
        var fail = true
        let model = HotkeyBindingsModel(bindings: .defaults, apply: { _, done in done(fail ? "no tap" : nil) })
        model.update { $0.key = .f6 }
        XCTAssertEqual(model.bindings, .defaults)
        XCTAssertEqual(model.error, "no tap")
        XCTAssertEqual(model.keyGeneration, 0)
        fail = false
        model.update { $0.key = .f6 }
        XCTAssertEqual(model.bindings.key, .f6)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.keyGeneration, 1, "a shortcut check started for F5 is now stale")
        model.update { $0.forward = .nothing }
        XCTAssertEqual(model.keyGeneration, 1, "a mouse role change keeps the check's key")
    }

    /// (4) Two buttons bound to dictation: the second button's press and release are swallowed while the first owns
    /// the press, so its release cannot end the first's hold.
    func testOverlappingDictationButtonsPairEachReleaseWithItsOwner() {
        var owner: Int64?
        XCTAssertEqual(pairMouseDictationAction(.keyDown, button: 4, owner: &owner), .keyDown)
        XCTAssertEqual(pairMouseDictationAction(.keyDown, button: 3, owner: &owner), .consume, "second button: no gesture")
        XCTAssertEqual(pairMouseDictationAction(.keyUp, button: 3, owner: &owner), .consume, "its release ends nothing")
        XCTAssertEqual(owner, 4)
        XCTAssertEqual(pairMouseDictationAction(.keyUp, button: 4, owner: &owner), .keyUp, "the owner's release ends it")
        XCTAssertNil(owner)
        XCTAssertEqual(pairMouseDictationAction(.keyDown, button: 3, owner: &owner), .keyDown, "then either may start")
        XCTAssertEqual(pairMouseDictationAction(.keyUp, button: 3, owner: &owner), .keyUp)
        var none: Int64?
        XCTAssertEqual(pairMouseDictationAction(.keyUp, button: 4, owner: &none), .keyUp,
                       "a release with no recorded press keeps today's behaviour")
        XCTAssertEqual(pairMouseDictationAction(.sendEnter, button: 3, owner: &none), .sendEnter)
    }
}
