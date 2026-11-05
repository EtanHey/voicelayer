import AppKit
@testable import VoiceBarUI
import XCTest

/// Settings › Dictionary search (U3 spec): "Add '<query>'" on no result, the search field's clear/Escape/focus and
/// its paste path (the plain field; see DictionarySearchPasteTests), and the Included terms sample.
@MainActor
final class DictionarySearchTests: XCTestCase {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func dictionarySection() throws -> String {
        let source = try source("SettingsView.swift")
        return try XCTUnwrap(source.components(separatedBy: "// MARK: - Dictionary Tab").dropFirst().first?
            .components(separatedBy: "// MARK: - Helpers").first)
    }

    // MARK: - Search: no result, Add '<query>', clear, focus

    func testNoMatchOffersAddForTheTrimmedQueryOnlyOnceLoaded() {
        XCTAssertEqual(DictionarySearchPresentation.addSuggestion(
            search: "  kubectl ", loaded: true, personalMatches: 0, includedMatches: 0), "kubectl")
        XCTAssertEqual(DictionarySearchPresentation.addSuggestionTitle("kubectl"), "Add \u{201C}kubectl\u{201D}")
        XCTAssertNil(DictionarySearchPresentation.addSuggestion(
            search: "kubectl", loaded: false, personalMatches: 0, includedMatches: 0), "never before the first load")
        XCTAssertNil(DictionarySearchPresentation.addSuggestion(
            search: "kube", loaded: true, personalMatches: 1, includedMatches: 0))
        XCTAssertNil(DictionarySearchPresentation.addSuggestion(
            search: "kube", loaded: true, personalMatches: 0, includedMatches: 2), "an included match is a match")
        XCTAssertNil(DictionarySearchPresentation.addSuggestion(
            search: "   ", loaded: true, personalMatches: 0, includedMatches: 0), "whitespace is not a search")
    }

    func testAddSuggestionOpensTheExistingSheetPrefilledWithTheQuery() throws {
        let section = try Self.dictionarySection()
        let noMatches = try XCTUnwrap(section.components(separatedBy: "private func dictionaryNoMatches(")
            .dropFirst().first?.components(separatedBy: "private func dictionaryUndoBar(").first)
        XCTAssertTrue(noMatches.contains("termSheet = DictionaryTermEdit(correct: query)"))
        XCTAssertEqual(DictionaryTermEdit(correct: "kubectl").correct, "kubectl")
        XCTAssertFalse(DictionaryTermEdit(correct: "kubectl").isEditing, "it is an Add, not an edit")
    }

    /// The search stays the existing plain field (normal macOS editing and ⌘V); no second paste path or F5 hook.
    func testSearchUsesTheExistingFieldWithClearEscapeAndFocus() throws {
        let section = try Self.dictionarySection()
        let row = try XCTUnwrap(section.components(separatedBy: "private var searchRow: some View {")
            .dropFirst().first?.components(separatedBy: "private func dictionaryEntryCard(").first)
        XCTAssertTrue(row.contains(".dictionaryTextField()"))
        XCTAssertTrue(row.contains(".focused($focusedEditorField, equals: .search)"))
        XCTAssertTrue(row.contains(".onExitCommand { dictionarySearch = \"\" }"))
        XCTAssertTrue(row.contains("dictionarySearch = \"\"\n                    focusedEditorField = .search"),
                      "the clear button empties the query and keeps editing focus in the field")
        for forbidden in ["NSPasteboard", "onPasteCommand", "PasteboardIsolation", "F5", "keyboardShortcut(\"v\""] {
            XCTAssertFalse(section.contains(forbidden), "Dictionary must not add its own \(forbidden) path")
        }
    }

    // MARK: - Included terms

    func testIncludedSampleUsesTheDaemonRowsAndTheSpecCopy() {
        let rows = (1...12).map { STTDictionaryEntry(canonical: "Term\($0)", variants: []) }
        XCTAssertEqual(DictionarySearchPresentation.includedSample(rows), (1...8).map { "Term\($0)" })
        XCTAssertEqual(DictionarySearchPresentation.includedSample([]), [])
        XCTAssertEqual(DictionarySearchPresentation.includedExplanation,
                       "These ship with VoiceBar and can't be edited. A term of your own wins over an included one.")
    }
}
