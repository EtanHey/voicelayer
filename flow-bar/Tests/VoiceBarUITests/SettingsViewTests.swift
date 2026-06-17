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

    func testPromptTermAddTrimsCallsCallbackUpdatesLocalListAndClearsField() {
        var localTerms = ["BrainLayer"]
        var newTermText = "  VoiceLayer  "
        var addedTerms: [String] = []

        SettingsDictionaryMutations.commitNewPromptTerm(
            newTermText: &newTermText,
            localTerms: &localTerms,
            onAddPromptTerm: { addedTerms.append($0) }
        )

        XCTAssertEqual(addedTerms, ["VoiceLayer"])
        XCTAssertEqual(localTerms, ["BrainLayer", "VoiceLayer"])
        XCTAssertEqual(newTermText, "")
    }

    func testPromptTermDeleteCallsCallbackAndRemovesLocalTerm() {
        var localTerms = ["BrainLayer", "VoiceLayer"]
        var removedTerms: [String] = []

        SettingsDictionaryMutations.deletePromptTerm(
            "VoiceLayer",
            localTerms: &localTerms,
            onRemovePromptTerm: { removedTerms.append($0) }
        )

        XCTAssertEqual(removedTerms, ["VoiceLayer"])
        XCTAssertEqual(localTerms, ["BrainLayer"])
    }

    func testCorrectionSaveTrimsCallsCallbackUpdatesLocalListAndClearsFields() {
        var localAliases = [STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer")]
        var correctText = "  VoiceLayer  "
        var wrongText = " voice lair "
        var selectedAlias: STTVocabularyAliasPreview?
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.saveCorrection(
            correctText: &correctText,
            wrongText: &wrongText,
            selectedAlias: &selectedAlias,
            localAliases: &localAliases,
            onRemoveVocabularyAlias: { _ in XCTFail("Adding a new correction must not remove an alias") },
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertEqual(addedAliases.map(\.correct), ["VoiceLayer"])
        XCTAssertEqual(addedAliases.map(\.wrong), ["voice lair"])
        XCTAssertEqual(
            localAliases,
            [
                STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer"),
                STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer"),
            ]
        )
        XCTAssertEqual(correctText, "")
        XCTAssertEqual(wrongText, "")
        XCTAssertNil(selectedAlias)
    }

    func testCorrectionEditReplacesLocalAliasInPlaceAndClearsFields() {
        let existingAlias = STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer")
        var localAliases = [
            STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer"),
            existingAlias,
        ]
        var correctText = "  VoiceBar  "
        var wrongText = " voice bar "
        var selectedAlias: STTVocabularyAliasPreview? = existingAlias
        var removedAliases: [STTVocabularyAliasPreview] = []
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.saveCorrection(
            correctText: &correctText,
            wrongText: &wrongText,
            selectedAlias: &selectedAlias,
            localAliases: &localAliases,
            onRemoveVocabularyAlias: { removedAliases.append($0) },
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertEqual(removedAliases, [existingAlias])
        XCTAssertEqual(addedAliases.map(\.correct), ["VoiceBar"])
        XCTAssertEqual(addedAliases.map(\.wrong), ["voice bar"])
        XCTAssertEqual(
            localAliases,
            [
                STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer"),
                STTVocabularyAliasPreview(from: "voice bar", to: "VoiceBar"),
            ],
            "Editing must replace the local row at the same index instead of jumping it to the bottom"
        )
        XCTAssertEqual(correctText, "")
        XCTAssertEqual(wrongText, "")
        XCTAssertNil(selectedAlias)
    }

    func testCorrectionDeleteCallsCallbackRemovesLocalAliasAndClearsSelectedDraft() {
        let alias = STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer")
        var localAliases = [
            STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer"),
            alias,
        ]
        var correctText = "VoiceLayer"
        var wrongText = "voice lair"
        var selectedAlias: STTVocabularyAliasPreview? = alias
        var removedAliases: [STTVocabularyAliasPreview] = []

        SettingsDictionaryMutations.deleteCorrection(
            alias,
            correctText: &correctText,
            wrongText: &wrongText,
            selectedAlias: &selectedAlias,
            localAliases: &localAliases,
            onRemoveVocabularyAlias: { removedAliases.append($0) }
        )

        XCTAssertEqual(removedAliases, [alias])
        XCTAssertEqual(localAliases, [STTVocabularyAliasPreview(from: "brain lair", to: "BrainLayer")])
        XCTAssertEqual(correctText, "")
        XCTAssertEqual(wrongText, "")
        XCTAssertNil(selectedAlias)
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

    func testPerformanceEffortPickerUpdatesLocalStateBeforeNotifyingApp() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(
            source.contains(
                """
                set: { effort in
                                        selectedPerformanceEffort = effort
                                        onSelectPerformanceEffort(effort)
                                    }
                """
            ),
            "A single segmented-picker click must update SettingsView state before AppDelegate refreshes the root view"
        )
    }

    /// Bugbot PR #261: the apply script remaps ONLY the dictation key; physical
    /// F5 reaches the event tap directly (keycode 96). The copy must not claim
    /// F5 itself is remapped.
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
