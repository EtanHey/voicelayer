@testable import VoiceBarUI
import XCTest

/// R4/D1 (Etan's 2.2.24 review #3; UI pass #17 and #19): Dictionary edits happen in ONE Add/Edit sheet. There is
/// no inline "-s" box with Cancel/Save, and no "+ misheard as…" row under every term.
final class DictionaryTermSheetTests: XCTestCase {
    private final class Calls {
        var addedTerms: [String] = []
        var removedTerms: [String] = []
        var addedAliases: [String] = []
        var removedAliases: [String] = []
    }

    private func apply(_ edit: DictionaryTermEdit, to entries: inout [STTDictionaryEntry]) -> (String?, Calls) {
        let calls = Calls()
        let result = SettingsDictionaryMutations.apply(
            edit,
            localEntries: &entries,
            onAddPromptTerm: { calls.addedTerms.append($0) },
            onRemovePromptTerm: { calls.removedTerms.append($0) },
            onAddVocabularyAlias: { calls.addedAliases.append("\($1)→\($0)") },
            onRemoveVocabularyAlias: { calls.removedAliases.append("\($0.from)→\($0.to)") }
        )
        return (result, calls)
    }

    // MARK: - Behaviour

    func testAddingATermOnlyAppendsItAsAPromptTerm() {
        var entries = [STTDictionaryEntry(canonical: "BrainLayer", variants: [])]
        let (result, calls) = apply(DictionaryTermEdit(correct: "  VoiceLayer "), to: &entries)

        XCTAssertEqual(result, "VoiceLayer")
        XCTAssertEqual(entries.map(\.canonical), ["BrainLayer", "VoiceLayer"])
        XCTAssertEqual(calls.addedTerms, ["VoiceLayer"])
        XCTAssertEqual(calls.addedAliases, [])
    }

    func testAddingATermWithAMisheardSpellingStoresTheAlias() {
        var entries: [STTDictionaryEntry] = []
        let (result, calls) = apply(DictionaryTermEdit(correct: "VoiceLayer", wrong: "voice later"), to: &entries)

        XCTAssertEqual(result, "VoiceLayer")
        XCTAssertEqual(entries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice later"])])
        XCTAssertEqual(calls.addedAliases, ["voice later→VoiceLayer"])
    }

    func testAddingAMisheardSpellingToAnExistingTermLandsOnItCaseInsensitively() {
        var entries = [STTDictionaryEntry(canonical: "SwiftUI", variants: ["swift you eye"])]
        let (result, _) = apply(DictionaryTermEdit(correct: "swiftui", wrong: "swift you I"), to: &entries)

        XCTAssertEqual(result, "SwiftUI")
        XCTAssertEqual(entries, [STTDictionaryEntry(canonical: "SwiftUI", variants: ["swift you eye", "swift you I"])])
    }

    func testEditingRemovesVariantsRenamesAndAddsANewVariantInOneSave() {
        let original = STTDictionaryEntry(canonical: "VoiceLayr", variants: ["voice layer", "voice later"])
        var entries = [original]
        var edit = DictionaryTermEdit(original: original)
        edit.correct = "VoiceLayer"
        edit.wrong = "voice lair"
        edit.removedVariants = ["voice later"]
        let (result, calls) = apply(edit, to: &entries)

        XCTAssertEqual(result, "VoiceLayer")
        XCTAssertEqual(entries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice layer", "voice lair"])])
        XCTAssertEqual(calls.removedAliases, ["voice later→VoiceLayr"])
        XCTAssertEqual(calls.addedTerms, ["VoiceLayer"])
        XCTAssertEqual(calls.removedTerms, ["VoiceLayr"])
        XCTAssertEqual(calls.addedAliases, ["voice layer→VoiceLayer", "voice lair→VoiceLayer"])
    }

    func testAnUnchangedEditWritesNothing() {
        let original = STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice later"])
        var entries = [original]
        let (result, calls) = apply(DictionaryTermEdit(original: original), to: &entries)

        XCTAssertEqual(result, "VoiceLayer")
        XCTAssertEqual(entries, [original])
        XCTAssertTrue(calls.addedTerms.isEmpty && calls.removedTerms.isEmpty)
        XCTAssertTrue(calls.addedAliases.isEmpty && calls.removedAliases.isEmpty)
    }

    func testTheEditModelKeepsOnlyTheVariantsNotMarkedForRemoval() {
        var edit = DictionaryTermEdit(original: STTDictionaryEntry(canonical: "A", variants: ["x", "y", "z"]))
        edit.removedVariants = ["y"]

        XCTAssertEqual(edit.correct, "A", "editing starts from the current spelling")
        XCTAssertEqual(edit.keptVariants, ["x", "z"])
        XCTAssertTrue(edit.isEditing)
        XCTAssertFalse(DictionaryTermEdit(correct: "  ").canSave)
    }

    // MARK: - Layout pins (SwiftUI builds no AX tree offscreen)

    func testThereIsNoInlineEditorOrPerTermMisheardRow() throws {
        let source = try source("SettingsView.swift")

        XCTAssertFalse(source.contains("addVariantInlineEditor"))
        XCTAssertFalse(source.contains("TextField(\"Term\""))
        XCTAssertFalse(source.contains("Label(\"misheard as…\""))
        XCTAssertFalse(source.contains("@State private var editingRowID"))
        XCTAssertFalse(source.contains("@State private var addingVariantFor"))
    }

    func testPencilAndDoubleClickOpenTheSameSheetAsAdd() throws {
        let source = try source("SettingsView.swift")

        XCTAssertTrue(source.contains(".sheet(item: $termSheet)"))
        XCTAssertTrue(source.contains("termSheet = DictionaryTermEdit()"), "Add term opens the sheet")
        XCTAssertTrue(source.contains("termSheet = DictionaryTermEdit(original: entry)"), "the pencil opens it")
        XCTAssertTrue(source.contains(".onTapGesture(count: 2)"), "a double-click opens it")
    }

    func testRowActionsHaveAtLeast24PointTargets() throws {
        let source = try source("SettingsView.swift")
        let header = try XCTUnwrap(
            source.components(separatedBy: "private func dictionaryEntryHeader(").dropFirst().first?
                .components(separatedBy: "@ViewBuilder\n    private func deleteDictionaryEntryButton").first
        )

        XCTAssertTrue(header
            .contains(".frame(width: DictionaryCardLayout.actionTarget, height: DictionaryCardLayout.actionTarget)"))
        XCTAssertTrue(source.contains("static let actionTarget: CGFloat = 24"))
        XCTAssertTrue(header.contains(".accessibilityLabel(\"Edit term \\(entry.canonical)\")"))
    }

    func testEditorStateResetsWhenTheTabAppears() throws {
        let source = try source("SettingsView.swift")

        XCTAssertTrue(source.contains(".onAppear {\n            resetDictionaryEditors()"))
        XCTAssertTrue(source.contains("private func resetDictionaryEditors()"))
    }

    func testTheSheetListsExistingVariantsWithRemoveInEditMode() throws {
        let source = try source("DictionaryAddSheetView.swift")

        XCTAssertTrue(source.contains("ForEach(edit.keptVariants"))
        XCTAssertTrue(source.contains("edit.removedVariants.append(variant)"))
        XCTAssertTrue(source.contains("edit.isEditing ? \"Save\" : \"Add\""))
        XCTAssertTrue(source.contains("edit.isEditing ? \"Edit Term\" : \"Add to Dictionary\""))
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
