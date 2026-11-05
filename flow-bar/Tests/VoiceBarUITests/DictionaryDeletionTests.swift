@testable import VoiceBarUI
import XCTest

/// Settings › Dictionary delete helper (U3 spec): the 4-second Undo window, in-place restore, when the daemon removal
/// is committed, and the selection a delete leaves. Pure; the pane wiring is pinned in DictionaryPaneTests.
final class DictionaryDeletionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 50_000)
    private let entries = [
        STTDictionaryEntry(canonical: "Kubernetes", variants: ["cube netties"]),
        STTDictionaryEntry(canonical: "SwiftUI", variants: []),
        STTDictionaryEntry(canonical: "Zod", variants: ["sod"]),
    ]

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
}
