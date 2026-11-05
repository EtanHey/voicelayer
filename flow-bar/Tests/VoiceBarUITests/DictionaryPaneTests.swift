import AppKit
@testable import VoiceBarUI
import XCTest

/// Settings › Dictionary (U3 spec): no-result Add, clear/edit focus, Delete with a 4-second Undo and the selection
/// it leaves, row anatomy and helper-text contrast.
@MainActor
final class DictionaryPaneTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 50_000)
    private let entries = [
        STTDictionaryEntry(canonical: "Kubernetes", variants: ["cube netties"]),
        STTDictionaryEntry(canonical: "SwiftUI", variants: []),
        STTDictionaryEntry(canonical: "Zod", variants: ["sod"]),
    ]

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

    // MARK: - Delete, Undo deadline, selection

    func testUndoInsideTheWindowRestoresTheTermInPlaceAndSendsNothing() throws {
        var local = entries
        var pending: DictionaryPendingDeletion?
        var removed: [String] = []
        DictionaryDeletion.begin("SwiftUI", localEntries: &local, pending: &pending, now: start,
                                 commit: { removed.append($0.canonical) })
        XCTAssertEqual(local.map(\.canonical), ["Kubernetes", "Zod"])
        XCTAssertEqual(DictionaryDeletion.undoMessage(try XCTUnwrap(pending)), "Deleted \u{201C}SwiftUI\u{201D}.")

        let restored = DictionaryDeletion.undo(localEntries: &local, pending: &pending,
                                               now: start.addingTimeInterval(3.99))
        XCTAssertEqual(restored?.canonical, "SwiftUI")
        XCTAssertEqual(local, entries, "same entry, same place, same variants")
        XCTAssertNil(pending)
        XCTAssertTrue(removed.isEmpty)
    }

    func testUndoAtTheDeadlineIsTooLate() {
        var local = entries
        var pending: DictionaryPendingDeletion?
        DictionaryDeletion.begin("Zod", localEntries: &local, pending: &pending, now: start, commit: { _ in })
        XCTAssertEqual(DictionaryPendingDeletion.undoWindow, 4)
        XCTAssertNil(DictionaryDeletion.undo(localEntries: &local, pending: &pending, now: start.addingTimeInterval(4)))
        XCTAssertEqual(local.map(\.canonical), ["Kubernetes", "SwiftUI"])
    }

    func testASecondDeleteCommitsTheFirstBeforeHidingTheNext() {
        var local = entries
        var pending: DictionaryPendingDeletion?
        var removed: [String] = []
        let commit: (STTDictionaryEntry) -> Void = { removed.append($0.canonical) }
        DictionaryDeletion.begin("Kubernetes", localEntries: &local, pending: &pending, now: start, commit: commit)
        DictionaryDeletion.begin("Zod", localEntries: &local, pending: &pending, now: start.addingTimeInterval(1),
                                 commit: commit)
        XCTAssertEqual(removed, ["Kubernetes"])
        XCTAssertEqual(pending?.entry.canonical, "Zod")
        XCTAssertEqual(pending?.deadline, start.addingTimeInterval(5), "each delete gets its own full window")
        XCTAssertEqual(local.map(\.canonical), ["SwiftUI"])
    }

    func testLeavingThePaneCommitsThePendingDeletion() {
        var local = entries
        var pending: DictionaryPendingDeletion?
        var removed: [String] = []
        DictionaryDeletion.begin("Zod", localEntries: &local, pending: &pending, now: start, commit: { _ in })
        DictionaryDeletion.commitNow(pending: &pending, commit: { removed.append($0.canonical) })
        XCTAssertEqual(removed, ["Zod"])
        XCTAssertNil(pending)
    }

    func testDeletingAnUnknownTermDoesNothing() {
        var local = entries
        var pending: DictionaryPendingDeletion?
        XCTAssertNil(DictionaryDeletion.begin("Nope", localEntries: &local, pending: &pending, now: start,
                                              commit: { _ in }))
        XCTAssertEqual(local, entries)
        XCTAssertNil(pending)
    }

    func testSelectionAfterDeleteMovesToTheNextRowThenThePrevious() {
        let rows = ["a", "b", "c"]
        XCTAssertEqual(DictionaryDeletion.selection(afterRemoving: "a", from: rows), "b")
        XCTAssertEqual(DictionaryDeletion.selection(afterRemoving: "c", from: rows), "b")
        XCTAssertNil(DictionaryDeletion.selection(afterRemoving: "a", from: ["a"]))
        XCTAssertNil(DictionaryDeletion.selection(afterRemoving: "x", from: rows))
    }

    func testArrowKeysMoveTheSelectionWithinTheVisibleRows() {
        let rows = ["a", "b", "c"]
        XCTAssertEqual(DictionaryDeletion.selection(movingFrom: nil, by: 1, in: rows), "a")
        XCTAssertEqual(DictionaryDeletion.selection(movingFrom: nil, by: -1, in: rows), "c")
        XCTAssertEqual(DictionaryDeletion.selection(movingFrom: "b", by: 1, in: rows), "c")
        XCTAssertEqual(DictionaryDeletion.selection(movingFrom: "c", by: 1, in: rows), "c")
        XCTAssertEqual(DictionaryDeletion.selection(movingFrom: "a", by: -1, in: rows), "a")
        XCTAssertNil(DictionaryDeletion.selection(movingFrom: "a", by: 1, in: []))
    }

    /// The production path: Delete/Backspace on the focused list, Undo with ⌘Z except while typing in the search,
    /// the reload gate held while a deletion is pending, and the daemon removal only on commit.
    func testPaneWiresDeleteKeyUndoAndTheReloadGate() throws {
        let source = try Self.source("SettingsView.swift")
        let section = try Self.dictionarySection()
        XCTAssertTrue(section.contains(".onDeleteCommand { deleteSelectedTerm() }"))
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

    func testRowActionsShowOnHoverOrSelectionAndStayReachable() throws {
        let section = try Self.dictionarySection()
        XCTAssertTrue(section.contains("let showsActions = isSelected || hoveredTermRowID == rowID"))
        XCTAssertTrue(section.contains(".opacity(showsActions ? 1 : 0)"))
        XCTAssertTrue(section.contains(".allowsHitTesting(showsActions)"))
        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Delete\")"))
        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Edit\")"))
    }

    // MARK: - Included terms

    func testIncludedSampleUsesTheDaemonRowsAndTheSpecCopy() {
        let rows = (1...12).map { STTDictionaryEntry(canonical: "Term\($0)", variants: []) }
        XCTAssertEqual(DictionarySearchPresentation.includedSample(rows), (1...8).map { "Term\($0)" })
        XCTAssertEqual(DictionarySearchPresentation.includedSample([]), [])
        XCTAssertEqual(DictionarySearchPresentation.includedExplanation,
                       "These ship with VoiceBar and can't be edited. A term of your own wins over an included one.")
    }

    // MARK: - Row anatomy (V12)

    func testControlsWrapUnderTheTextOnlyWhenTheTextColumnWouldDropBelowItsMinimum() {
        let controls: CGFloat = 84
        XCTAssertFalse(SettingsRowLayout.wrapsControls(width: 720 - 36, controlsWidth: controls, spacing: 8,
                                                       textMinWidth: SettingsRowLabel.textMinWidth))
        XCTAssertFalse(SettingsRowLayout.wrapsControls(width: 390 - 36, controlsWidth: controls, spacing: 8,
                                                       textMinWidth: SettingsRowLabel.textMinWidth))
        XCTAssertTrue(SettingsRowLayout.wrapsControls(width: 240, controlsWidth: controls, spacing: 8,
                                                      textMinWidth: SettingsRowLabel.textMinWidth))
    }

    func testTooltipOnlyForActuallyClippedText() {
        XCTAssertTrue(ClippingAwareText.isClipped(fullHeight: 48, limitedHeight: 32))
        XCTAssertFalse(ClippingAwareText.isClipped(fullHeight: 32, limitedHeight: 32))
        XCTAssertFalse(ClippingAwareText.isClipped(fullHeight: 32.3, limitedHeight: 32), "sub-pixel rounding")
        XCTAssertEqual(SettingsRowLabel.lineLimit, 2)
    }

    // MARK: - Helper text contrast (≥ 4.5:1, light and dark)

    func testHelperAndWarningTextMeetFourAndAHalfToOneOnTheWindowBackground() throws {
        for (name, appearanceName, helper, warning) in [
            ("light", NSAppearance.Name.aqua, SettingsPanePalette.helperLight, SettingsPanePalette.warningLight),
            ("dark", NSAppearance.Name.darkAqua, SettingsPanePalette.helperDark, SettingsPanePalette.warningDark),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var background = SettingsPanePalette.RGB(0)
            appearance.performAsCurrentDrawingAppearance {
                let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                background = SettingsPanePalette.RGB(
                    UInt32((color.redComponent * 255).rounded()) << 16
                        | UInt32((color.greenComponent * 255).rounded()) << 8
                        | UInt32((color.blueComponent * 255).rounded())
                )
            }
            XCTAssertGreaterThanOrEqual(SettingsPanePalette.contrast(helper, background), 4.5, "helper \(name)")
            XCTAssertGreaterThanOrEqual(SettingsPanePalette.contrast(warning, background), 4.5, "warning \(name)")
        }
    }

    func testContrastFormulaMatchesKnownWCAGValues() {
        XCTAssertEqual(SettingsPanePalette.contrast(.init(0x000000), .init(0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(SettingsPanePalette.contrast(.init(0x777777), .init(0xFFFFFF)), 4.48, accuracy: 0.01)
    }
}
