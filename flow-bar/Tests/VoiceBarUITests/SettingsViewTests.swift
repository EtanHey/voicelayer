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

    // MARK: - Dictionary canonical cards

    func testDictionaryCardsExposeDeleteAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(
            source.contains("deleteDictionaryEntryButton"),
            "each canonical term card needs an always-visible delete affordance"
        )
    }

    func testDictionaryCardsHaveVariantAddAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("addVariantButton"))
        XCTAssertTrue(source.contains("add misheard variant"))
    }

    func testVariantAddAffordanceUsesChipMatchingVerticalPadding() throws {
        let source = try settingsViewSource()
        let functionSource = try XCTUnwrap(source.functionBody(named: "addVariantButton"))

        XCTAssertTrue(functionSource.contains(".padding(.vertical, 5)"))
    }

    func testDictionaryTextActionsUseStyledButtons() throws {
        let source = try settingsViewSource()
        let borderedCount = source.components(separatedBy: ".buttonStyle(.bordered)").count - 1
        let prominentCount = source.components(separatedBy: ".buttonStyle(.borderedProminent)").count - 1

        XCTAssertGreaterThanOrEqual(borderedCount, 3)
        XCTAssertGreaterThanOrEqual(prominentCount, 3)
        XCTAssertTrue(source
            .contains(
                "Button(\"Cancel\") {\n                    cancelTermRename()\n                }\n                .buttonStyle(.bordered)"
            ))
        XCTAssertTrue(source
            .contains(
                "Button(\"Save\") {\n                    saveTermRename(entry.canonical)\n                }\n                .buttonStyle(.borderedProminent)"
            ))
        XCTAssertTrue(source
            .contains(
                "Button(\"Add\") {\n                saveVariant(entry.canonical)\n            }\n            .buttonStyle(.borderedProminent)"
            ))
        XCTAssertTrue(source
            .contains(
                "Button(\"Delete?\", role: .destructive) {\n                SettingsDictionaryMutations.confirmDeleteTerm("
            ))
        XCTAssertTrue(source.contains(".buttonStyle(.borderedProminent)\n            .tint(.red)"))
    }

    func testDictionaryDoesNotRenderOldSplitSections() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("DisclosureGroup"))
        XCTAssertFalse(source.contains("Prompt Terms"))
        XCTAssertFalse(source.contains("Corrections"))
    }

    func testAddTermUpdatesLocalEntriesImmediately() {
        var localEntries = [STTDictionaryEntry(canonical: "BrainLayer", variants: [])]
        var newTermText = "  VoiceLayer  "
        var addedTerms: [String] = []

        SettingsDictionaryMutations.commitNewTerm(
            newTermText: &newTermText,
            localEntries: &localEntries,
            onAddPromptTerm: { addedTerms.append($0) }
        )

        XCTAssertEqual(addedTerms, ["VoiceLayer"])
        XCTAssertEqual(
            localEntries,
            [
                STTDictionaryEntry(canonical: "BrainLayer", variants: []),
                STTDictionaryEntry(canonical: "VoiceLayer", variants: []),
            ]
        )
        XCTAssertEqual(newTermText, "")
    }

    func testRenameTermUpdatesLocalEntriesImmediatelyAndPreservesVariants() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair", "voice layer"]),
        ]
        var editText = "  VoiceBar  "
        var removedTerms: [String] = []
        var addedTerms: [String] = []
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.renameTerm(
            "VoiceLayer",
            editText: &editText,
            localEntries: &localEntries,
            onAddPromptTerm: { addedTerms.append($0) },
            onRemovePromptTerm: { removedTerms.append($0) },
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertEqual(addedTerms, ["VoiceBar"])
        XCTAssertEqual(removedTerms, ["VoiceLayer"])
        XCTAssertEqual(addedAliases.map(\.correct), ["VoiceBar", "VoiceBar"])
        XCTAssertEqual(addedAliases.map(\.wrong), ["voice lair", "voice layer"])
        XCTAssertEqual(
            localEntries,
            [STTDictionaryEntry(canonical: "VoiceBar", variants: ["voice lair", "voice layer"])]
        )
        XCTAssertEqual(editText, "")
    }

    func testRenameTermUnchangedDoesNotRemoveEntry() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"]),
        ]
        var editText = "  VoiceLayer  "
        var removedTerms: [String] = []
        var addedTerms: [String] = []
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.renameTerm(
            "VoiceLayer",
            editText: &editText,
            localEntries: &localEntries,
            onAddPromptTerm: { addedTerms.append($0) },
            onRemovePromptTerm: { removedTerms.append($0) },
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertTrue(addedTerms.isEmpty)
        XCTAssertTrue(removedTerms.isEmpty)
        XCTAssertTrue(addedAliases.isEmpty)
        XCTAssertEqual(localEntries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"])])
        XCTAssertEqual(editText, "")
    }

    func testRenameTermCaseOnlyDoesNotRemoveEntry() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"]),
        ]
        var editText = "voicelayer"
        var removedTerms: [String] = []
        var addedTerms: [String] = []

        SettingsDictionaryMutations.renameTerm(
            "VoiceLayer",
            editText: &editText,
            localEntries: &localEntries,
            onAddPromptTerm: { addedTerms.append($0) },
            onRemovePromptTerm: { removedTerms.append($0) },
            onAddVocabularyAlias: { _, _ in }
        )

        XCTAssertTrue(addedTerms.isEmpty)
        XCTAssertTrue(removedTerms.isEmpty)
        XCTAssertEqual(localEntries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"])])
        XCTAssertEqual(editText, "")
    }

    func testRenameTermToExistingCanonicalMergesVariants() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair", "voice layer"]),
            STTDictionaryEntry(canonical: "VoiceBar", variants: ["voice bar"]),
        ]
        var editText = "VoiceBar"
        var removedTerms: [String] = []
        var addedTerms: [String] = []
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.renameTerm(
            "VoiceLayer",
            editText: &editText,
            localEntries: &localEntries,
            onAddPromptTerm: { addedTerms.append($0) },
            onRemovePromptTerm: { removedTerms.append($0) },
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertTrue(addedTerms.isEmpty)
        XCTAssertEqual(removedTerms, ["VoiceLayer"])
        XCTAssertEqual(addedAliases.map(\.correct), ["VoiceBar", "VoiceBar"])
        XCTAssertEqual(addedAliases.map(\.wrong), ["voice lair", "voice layer"])
        XCTAssertEqual(
            localEntries,
            [STTDictionaryEntry(canonical: "VoiceBar", variants: ["voice bar", "voice lair", "voice layer"])]
        )
        XCTAssertEqual(editText, "")
    }

    func testDictionaryReconcilesIdleLocalEntriesFromVocabularySnapshot() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(
            source.contains(".onChange(of: vocabularyPreview())"),
            "Dictionary cards should reconcile with later daemon vocabulary snapshots"
        )
        XCTAssertTrue(
            source.contains("guard !hasPendingDictionaryEdit else { return }"),
            "Snapshot reconciliation must not clobber an active inline edit"
        )
    }

    func testDeleteTermRequiresConfirmationBeforeMutating() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"]),
        ]
        var pendingDelete: String?
        var removedTerms: [String] = []

        SettingsDictionaryMutations.requestDeleteTerm(
            "VoiceLayer",
            pendingDeleteCanonical: &pendingDelete
        )

        XCTAssertEqual(pendingDelete, "VoiceLayer")
        XCTAssertEqual(localEntries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"])])
        XCTAssertTrue(removedTerms.isEmpty)

        SettingsDictionaryMutations.confirmDeleteTerm(
            "VoiceLayer",
            pendingDeleteCanonical: &pendingDelete,
            localEntries: &localEntries,
            onRemovePromptTerm: { removedTerms.append($0) }
        )

        XCTAssertNil(pendingDelete)
        XCTAssertEqual(removedTerms, ["VoiceLayer"])
        XCTAssertEqual(localEntries, [])
    }

    func testAddVariantUpdatesLocalEntryImmediately() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"]),
        ]
        var variantText = " voice later "
        var addingVariantFor: String? = "VoiceLayer"
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.addVariant(
            canonical: "VoiceLayer",
            variantText: &variantText,
            addingVariantFor: &addingVariantFor,
            localEntries: &localEntries,
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertEqual(addedAliases.map(\.correct), ["VoiceLayer"])
        XCTAssertEqual(addedAliases.map(\.wrong), ["voice later"])
        XCTAssertEqual(
            localEntries,
            [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair", "voice later"])]
        )
        XCTAssertEqual(variantText, "")
        XCTAssertNil(addingVariantFor)
    }

    func testAddVariantMatchingCanonicalAliasKeyIsNoOp() {
        var localEntries = [
            STTDictionaryEntry(canonical: "La La", variants: ["la law"]),
        ]
        var variantText = " lala "
        var addingVariantFor: String? = "La La"
        var addedAliases: [(correct: String, wrong: String)] = []

        SettingsDictionaryMutations.addVariant(
            canonical: "La La",
            variantText: &variantText,
            addingVariantFor: &addingVariantFor,
            localEntries: &localEntries,
            onAddVocabularyAlias: { correct, wrong in addedAliases.append((correct, wrong)) }
        )

        XCTAssertTrue(addedAliases.isEmpty)
        XCTAssertEqual(localEntries, [STTDictionaryEntry(canonical: "La La", variants: ["la law"])])
        XCTAssertEqual(variantText, "")
        XCTAssertNil(addingVariantFor)
    }

    func testRemoveVariantUpdatesLocalEntryImmediately() {
        var localEntries = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair", "voice layer"]),
        ]
        var removedAliases: [STTVocabularyAliasPreview] = []

        SettingsDictionaryMutations.removeVariant(
            canonical: "VoiceLayer",
            variant: "voice lair",
            localEntries: &localEntries,
            onRemoveVocabularyAlias: { removedAliases.append($0) }
        )

        XCTAssertEqual(removedAliases, [STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer")])
        XCTAssertEqual(localEntries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice layer"])])
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

private extension String {
    func functionBody(named functionName: String) -> String? {
        guard let start = range(of: "private func \(functionName)") else { return nil }
        let suffix = self[start.lowerBound...]
        guard let nextFunction = suffix.dropFirst().range(of: "\n    private func ") else {
            return String(suffix)
        }
        return String(suffix[..<nextFunction.lowerBound])
    }
}
