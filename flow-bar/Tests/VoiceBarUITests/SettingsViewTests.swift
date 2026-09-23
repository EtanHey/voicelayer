import AppKit
import Observation
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Source-contract tests for the 2026-06-06 settings design pass
/// (Etan QA: invisible-until-hover inputs, missing term add/delete,
/// search reads as a label, stale gesture copy).
final class SettingsViewTests: XCTestCase {
    @MainActor
    func testVocabularyRevisionObserverRefreshesOnlyWhenRevisionChanges() {
        let model = VocabularyRevisionModel()
        var refreshCount = 0
        let host = NSHostingView(
            rootView: VocabularyRevisionHarness(model: model) {
                refreshCount += 1
            }
        )
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(refreshCount, 0)

        model.revision = 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(refreshCount, 1)

        model.revision = 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(refreshCount, 1)

        model.revision = 2
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(refreshCount, 2)
    }

    // MARK: - Field visibility (the invisible-until-hover class dies)

    func testDictionaryInputsUseVisibleFieldTreatmentAtRest() throws {
        let source = try settingsViewSource()
        let visibleFieldCount = source.components(separatedBy: ".dictionaryTextField()").count - 1

        XCTAssertGreaterThanOrEqual(visibleFieldCount, 3, "search, rename, and variant fields need visible styling")
        let sheetURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/DictionaryAddSheetView.swift")
        let sheetSource = try String(contentsOf: sheetURL)
        XCTAssertEqual(sheetSource.components(separatedBy: ".dictionaryTextField()").count - 1, 2)
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

    func testBundledDictionaryRowsHaveNoEditAffordance() throws {
        let source = try settingsViewSource()
        XCTAssertTrue(source.contains("isEditable: false"))
        XCTAssertTrue(source.contains("ForEach(included, id: \\.rowID)"))
    }

    func testSameNamePersonalEditDoesNotOpenBundledEditor() {
        let entry = STTDictionaryEntry(canonical: "Shared", variants: [])
        let bundled = STTDictionaryDisplayEntry(source: "bundled", entry: entry)
        let personal = STTDictionaryDisplayEntry(source: "personal", entry: entry)

        XCTAssertTrue(SettingsDictionaryEditing.isEditing(
            rowID: personal.rowID, isEditable: personal.isPersonal, activeRowID: personal.rowID
        ))
        XCTAssertFalse(SettingsDictionaryEditing.isEditing(
            rowID: bundled.rowID, isEditable: bundled.isPersonal, activeRowID: personal.rowID
        ))
    }

    func testDictionaryCardsHaveVariantAddAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("addVariantButton"))
        XCTAssertTrue(source.contains("misheard as…"))
    }

    func testVariantAddAffordanceUsesChipMatchingVerticalPadding() throws {
        let source = try settingsViewSource()
        let functionSource = try XCTUnwrap(source.functionBody(named: "addVariantButton"))

        XCTAssertTrue(functionSource.contains(".padding(.vertical, 5)"))
    }

    func testDictionaryTextActionsUseStyledButtons() throws {
        let source = try settingsViewSource()
        let addVariantSource = try XCTUnwrap(source.functionBody(named: "addVariantInlineEditor"))
        let deleteButtonSource = try XCTUnwrap(source.functionBody(named: "deleteDictionaryEntryButton"))
        let borderedCount = source.components(separatedBy: ".buttonStyle(.bordered)").count - 1
        let prominentCount = source.components(separatedBy: ".buttonStyle(.borderedProminent)").count - 1

        XCTAssertGreaterThanOrEqual(borderedCount, 2)
        XCTAssertGreaterThanOrEqual(prominentCount, 2)
        XCTAssertTrue(addVariantSource.contains("Button(\"Cancel\") {"))
        XCTAssertTrue(addVariantSource.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(addVariantSource.contains("Button(\"Add\") {"))
        XCTAssertTrue(addVariantSource.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(deleteButtonSource
            .contains(
                "Button(\"Delete?\", role: .destructive) {\n                SettingsDictionaryMutations.confirmDeleteTerm("
            ))
        XCTAssertTrue(deleteButtonSource.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(deleteButtonSource.contains(".tint(.red)"))
    }

    func testDeleteConfirmationHeaderHidesEditButton() throws {
        let source = try settingsViewSource()
        let headerSource = try XCTUnwrap(source.functionBody(named: "dictionaryEntryHeader"))
        let deleteConfirmBranch = try XCTUnwrap(headerSource.range(of: "if pendingDeleteCanonical == entry.canonical"))
        let editButton = headerSource.range(of: "beginTermRename(rowID: rowID, canonical: entry.canonical)")

        XCTAssertNotNil(editButton)
        XCTAssertTrue(
            try XCTUnwrap(editButton?.lowerBound) > deleteConfirmBranch.upperBound,
            "the edit pencil must only render outside the delete-confirm branch"
        )
    }

    func testAddVariantInlineInputUsesOptionDAccentStyleAtRest() throws {
        let source = try settingsViewSource()
        let functionSource = try XCTUnwrap(source.functionBody(named: "addVariantInlineEditor"))

        XCTAssertTrue(functionSource.contains(".padding(.vertical, DictionaryCardLayout.inlineFieldVerticalPadding)"))
        XCTAssertTrue(functionSource.contains(".padding(.horizontal, 12)"))
        XCTAssertTrue(functionSource.contains(".fill(addVariantInputFill)"))
        XCTAssertTrue(functionSource.contains(".stroke(Color.accentColor, lineWidth: 1.5)"))
        XCTAssertTrue(functionSource.contains("RoundedRectangle(cornerRadius: 8)"))
    }

    func testDictionaryEditUsesNativeAlignedActionRow() throws {
        let source = try settingsViewSource()
        let headerSource = try XCTUnwrap(source.functionBody(named: "dictionaryEntryHeader"))

        XCTAssertTrue(headerSource.contains("VStack(alignment: .leading, spacing: 10)"))
        XCTAssertTrue(headerSource.contains("HStack(spacing: 8)"))
        XCTAssertTrue(headerSource.contains("Spacer()"))
        XCTAssertTrue(headerSource.contains("Button(\"Cancel\")"))
        XCTAssertTrue(headerSource.contains("Button(\"Save\")"))
        XCTAssertTrue(headerSource.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(headerSource.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(headerSource.contains(".controlSize(.regular)"))
    }

    func testAddVariantInlineInputAndButtonsShareHeight() throws {
        let source = try settingsViewSource()
        let functionSource = try XCTUnwrap(source.functionBody(named: "addVariantInlineEditor"))

        XCTAssertTrue(source.contains("static let inlineControlHeight"))
        XCTAssertTrue(functionSource.contains(".padding(.vertical, DictionaryCardLayout.inlineFieldVerticalPadding)"))
        XCTAssertGreaterThanOrEqual(
            functionSource.components(separatedBy: ".frame(height: DictionaryCardLayout.inlineControlHeight)")
                .count - 1,
            3,
            "add-variant input, Add button, and Cancel button must be the same height"
        )
        XCTAssertGreaterThanOrEqual(
            functionSource.components(separatedBy: ".controlSize(.small)").count - 1,
            2,
            "add-variant action buttons need compact macOS control sizing"
        )
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
            source.contains("SettingsVocabularyRevisionObserver("),
            "Dictionary cards should observe later daemon vocabulary revisions"
        )
        XCTAssertTrue(
            source.contains("onRefresh: { loadDictionaryPreview() }"),
            "A revision change should project the new snapshot into local dictionary cards"
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

    func testShortcutCheckReportsObservedStatusWithoutChangingSettings() throws {
        XCTAssertEqual(
            SettingsShortcutCheck.message(
                hotkeyEnabled: true, missingPermissions: [], relayReady: true,
                relaySummary: "Relay ready"
            ),
            "Shortcut ready: F5 listener and relay are active."
        )
        XCTAssertTrue(SettingsShortcutCheck.message(
            hotkeyEnabled: false, missingPermissions: [.inputMonitoring], relayReady: false,
            relaySummary: "Relay needs attention"
        ).contains("Relay needs attention"))
        let source = try settingsViewSource()
        XCTAssertTrue(source.contains("Button(\"Check shortcut\")"))
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

@MainActor
@Observable
private final class VocabularyRevisionModel {
    var revision: UInt64 = 0
}

@MainActor
private struct VocabularyRevisionHarness: View {
    let model: VocabularyRevisionModel
    let onRefresh: () -> Void

    var body: some View {
        Color.clear.modifier(
            SettingsVocabularyRevisionObserver(
                revision: model.revision,
                onRefresh: onRefresh
            )
        )
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
