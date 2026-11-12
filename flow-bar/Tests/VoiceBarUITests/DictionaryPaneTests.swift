import AppKit
@testable import VoiceBarUI
import XCTest

/// Settings › Dictionary pane wiring (U3 spec): Trash and Delete/Backspace on the focused list, the 4-second Undo bar
/// (⌘Z outside the search), the reload gate, and the daemon removal only on commit.
@MainActor
final class DictionaryPaneTests: XCTestCase {
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

    /// The production path: Delete/Backspace on the focused list, Undo with ⌘Z except while typing in the search,
    /// the reload gate held while a deletion is pending, and the daemon removal only on commit.
    func testPaneWiresDeleteKeyUndoAndTheReloadGate() throws {
        let source = try Self.source("SettingsView.swift")
        let section = try Self.dictionarySection()
        XCTAssertTrue(section.contains(".onDeleteCommand { deleteSelectedTerm() }"))
        XCTAssertTrue(section.contains(".accessibilityLabel(\"Actions for term "), "VoiceOver reaches Delete through the named menu")
        XCTAssertTrue(section.contains(".focused($focusedEditorField, equals: .list)"))
        XCTAssertTrue(section.contains(
            ".keyboardShortcut(focusedEditorField == .search ? nil : KeyboardShortcut(\"z\", modifiers: .command))"))
        XCTAssertTrue(section.contains("DictionaryDeletion.commitIfExpired(now: Date(), pending: &pendingDeletion"))
        XCTAssertTrue(section.contains(".onDisappear {\n            DictionaryDeletion.commitNow("))
        XCTAssertTrue(source.contains("termSheet != nil || pendingDeletion != nil"),
                      "a pending deletion holds snapshot reloads back so the row can't reappear mid-window")
        let commit = try XCTUnwrap(section.components(separatedBy: "private func commitDeletion(")
            .dropFirst().first)
        XCTAssertTrue(commit.contains("onRemovePromptTerm(entry.canonical)"))
        XCTAssertTrue(commit.contains("dictionaryReloadGate.mutationSent()"))
        let deleteSelected = try XCTUnwrap(section.components(separatedBy: "private func deleteSelectedTerm()")
            .dropFirst().first?.components(separatedBy: "private func deleteTerm(").first)
        XCTAssertTrue(deleteSelected.contains("source: \"personal\""), "an included row can't be deleted")
    }


}
