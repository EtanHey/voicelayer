@testable import VoiceBarUI
import XCTest

/// Source-contract tests for the 2026-06-06 settings design pass
/// (Etan QA: invisible-until-hover inputs, missing term add/delete,
/// search reads as a label, stale gesture copy).
final class SettingsViewTests: XCTestCase {
    // MARK: - Field visibility (the invisible-until-hover class dies)

    func testDictionaryInputsUseVisibleFieldTreatmentAtRest() throws {
        let source = try settingsViewSource()
        let visibleFieldCount = source.components(separatedBy: ".dictionaryTextField()").count - 1

        XCTAssertGreaterThanOrEqual(
            visibleFieldCount, 4,
            "search + correct + transcribed + add-term fields must all be visible at rest"
        )
    }

    func testSearchFieldReadsAsSearchInput() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(
            source.contains("magnifyingglass"),
            "search input needs the system search affordance so it reads as the input, not a label"
        )
        XCTAssertFalse(
            source.contains("Section(\"Find\")"),
            "the Find section header impersonated the control; the search field stands alone"
        )
    }

    // MARK: - Corrections: delete directly on the row

    func testCorrectionRowsExposeDeleteAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(
            source.contains("deleteCorrectionButton"),
            "each correction row needs an always-visible delete affordance"
        )
    }

    // MARK: - Prompt terms: full add/delete

    func testPromptTermsHaveAddAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("promptTermAddRow"))
        XCTAssertTrue(source.contains("onAddPromptTerm"))
    }

    func testPromptTermsHaveDeleteAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("deletePromptTermButton"))
        XCTAssertTrue(source.contains("onRemovePromptTerm"))
    }

    // MARK: - Gesture copy tells the truth (HotkeyManager wiring)

    func testGestureCopyMatchesActualHandlerBehavior() {
        XCTAssertTrue(
            VoiceBarHotkeyContract.doubleTapDescription.localizedCaseInsensitiveContains("lock"),
            "double-tap locks the active recording (GestureStateMachine.onDoubleTap); copy said 'Not assigned'"
        )
        XCTAssertTrue(
            VoiceBarHotkeyContract.singleTapDescription.localizedCaseInsensitiveContains("stop"),
            "single tap stops active recording/speech (CommandRouter.handleHotkeySingleTap); copy said 'No action'"
        )
    }

    // MARK: - Hotkey chain display

    func testShortcutChainLabelReflectsRemapDetection() {
        XCTAssertEqual(
            VoiceBarHotkeyContract.shortcutChainLabel(remapDetected: true),
            "F5  ·  🎤 → F18"
        )
        XCTAssertEqual(
            VoiceBarHotkeyContract.shortcutChainLabel(remapDetected: false),
            "F5"
        )
    }

    // Bugbot PR #261: the apply script remaps ONLY the dictation key; physical
    // F5 reaches the event tap directly (keycode 96). The copy must not claim
    // F5 itself is remapped.
    func testRemapExplanationDoesNotClaimF5IsRemapped() {
        XCTAssertTrue(
            VoiceBarHotkeyContract.remapExplanation.contains("com.voicelayer.f5-to-f18-hidutil")
        )
        XCTAssertTrue(
            VoiceBarHotkeyContract.remapExplanation.contains("listens for F5 directly")
        )
        XCTAssertFalse(
            VoiceBarHotkeyContract.remapExplanation.contains("F5 and the dictation key")
        )
    }

    // MARK: - Helpers

    private func settingsViewSource() throws -> String {
        let settingsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("SettingsView.swift")
        return try String(contentsOf: settingsURL)
    }
}
