import Foundation

/// A term removed from "Your terms" that can still be put back. The row disappears at once; the removal is sent
/// to the daemon only when the Undo window closes, so Undo restores exactly what was there and never races a
/// remove/re-add round trip.
///
/// AIDEV-NOTE: while one is pending, `hasPendingDictionaryEdit` holds snapshot reloads back (the reload gate), so a
/// daemon snapshot can't bring the hidden row back mid-window. Leaving the pane, opening the term sheet, or deleting
/// another term commits the pending one first. If VoiceBar quits inside the window the term is simply kept.
struct DictionaryPendingDeletion: Equatable {
    static let undoWindow: TimeInterval = 4

    let entry: STTDictionaryEntry
    /// Where the entry sat in `localEntries`, so Undo puts it back in place.
    let index: Int
    let deadline: Date

    func isExpired(at now: Date) -> Bool { now >= deadline }
}

enum DictionaryDeletion {
    /// Hides `canonical` now and returns the pending deletion. A deletion already pending is committed first.
    @discardableResult
    static func begin(
        _ canonical: String,
        localEntries: inout [STTDictionaryEntry],
        pending: inout DictionaryPendingDeletion?,
        now: Date,
        commit: (STTDictionaryEntry) -> Void
    ) -> DictionaryPendingDeletion? {
        commitNow(pending: &pending, commit: commit)
        guard let index = localEntries.firstIndex(where: { $0.canonical == canonical }) else { return nil }
        let entry = localEntries.remove(at: index)
        let deletion = DictionaryPendingDeletion(
            entry: entry, index: index, deadline: now.addingTimeInterval(DictionaryPendingDeletion.undoWindow)
        )
        pending = deletion
        return deletion
    }

    /// Puts the pending entry back where it was. Returns it, or nil when nothing could be undone (expired/none).
    @discardableResult
    static func undo(
        localEntries: inout [STTDictionaryEntry],
        pending: inout DictionaryPendingDeletion?,
        now: Date
    ) -> STTDictionaryEntry? {
        guard let deletion = pending, !deletion.isExpired(at: now) else { return nil }
        pending = nil
        guard !localEntries.contains(where: { DictionaryTermEdit.sameTerm($0.canonical, deletion.entry.canonical) })
        else { return deletion.entry }
        localEntries.insert(deletion.entry, at: min(deletion.index, localEntries.count))
        return deletion.entry
    }

    /// Sends the removal when the window has closed. True when it committed.
    @discardableResult
    static func commitIfExpired(
        now: Date,
        pending: inout DictionaryPendingDeletion?,
        commit: (STTDictionaryEntry) -> Void
    ) -> Bool {
        guard let deletion = pending, deletion.isExpired(at: now) else { return false }
        pending = nil
        commit(deletion.entry)
        return true
    }

    static func commitNow(pending: inout DictionaryPendingDeletion?, commit: (STTDictionaryEntry) -> Void) {
        guard let deletion = pending else { return }
        pending = nil
        commit(deletion.entry)
    }

    /// The row selected after `rowID` is removed: the next row, else the previous one, else none.
    static func selection(afterRemoving rowID: String, from orderedRowIDs: [String]) -> String? {
        guard let index = orderedRowIDs.firstIndex(of: rowID) else { return nil }
        if index + 1 < orderedRowIDs.count { return orderedRowIDs[index + 1] }
        return index > 0 ? orderedRowIDs[index - 1] : nil
    }

    /// Arrow-key selection over the visible rows; starts at the first or last row when nothing is selected.
    static func selection(movingFrom rowID: String?, by offset: Int, in orderedRowIDs: [String]) -> String? {
        guard !orderedRowIDs.isEmpty else { return nil }
        guard let rowID, let index = orderedRowIDs.firstIndex(of: rowID) else {
            return offset >= 0 ? orderedRowIDs.first : orderedRowIDs.last
        }
        return orderedRowIDs[max(0, min(orderedRowIDs.count - 1, index + offset))]
    }

    static func undoMessage(_ deletion: DictionaryPendingDeletion) -> String {
        "Deleted \u{201C}\(deletion.entry.canonical)\u{201D}."
    }
}

enum DictionarySearchPresentation {
    /// "Add '<query>'" when a loaded dictionary has no row for the search: the trimmed query, else nil.
    static func addSuggestion(search: String, loaded: Bool, personalMatches: Int, includedMatches: Int) -> String? {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !query.isEmpty, personalMatches == 0, includedMatches == 0 else { return nil }
        return query
    }

    static func addSuggestionTitle(_ query: String) -> String {
        "Add \u{201C}\(query)\u{201D}"
    }

    /// A few included terms shown as chips while the list is closed: the daemon's own rows, in display order.
    static func includedSample(_ entries: [STTDictionaryEntry], limit: Int = 8) -> [String] {
        Array(entries.prefix(limit).map(\.canonical))
    }

    static let includedExplanation =
        "These ship with VoiceBar and can't be edited. A term of your own wins over an included one."
}
