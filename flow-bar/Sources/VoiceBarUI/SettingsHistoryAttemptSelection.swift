import Foundation

/// View state only. Latest completed output is a display default, never a persisted STATE pointer.
/// Explicit selection survives a refresh; no text is borrowed from another attempt.
struct SettingsHistoryAttemptSelection: Equatable {
    private(set) var entryID: String
    private(set) var recordingPath: String
    private(set) var history: SettingsHistoryAttemptHistory?
    private(set) var selectedAttemptID: String?
    private(set) var followsLatestResult = true
    private(set) var selectionUnavailable = false
    private(set) var revision = 0

    init(entry: SettingsHistoryEntry) {
        entryID = entry.id
        recordingPath = entry.audioPath.standardizedFileURL.path
    }

    /// A token fences refreshes as well as record switches, even when an injected reader ignores cancellation.
    mutating func beginRead() -> Int { revision &+= 1; return revision }

    @discardableResult
    mutating func receive(_ value: SettingsHistoryAttemptHistory?, entry: SettingsHistoryEntry, token: Int) -> Bool {
        guard token == revision, entry.id == entryID,
              entry.audioPath.standardizedFileURL.path == recordingPath else { return false }
        let matched = value?.matching(entry.audioPath)
        if let matched, matched.attempts.count != Set(matched.attempts.map(\.id)).count {
            history = nil; selectedAttemptID = nil; selectionUnavailable = true
            return true
        }
        history = matched
        if followsLatestResult {
            selectedAttemptID = matched?.attempts.last(where: { $0.status == .completed && $0.hasSavedText })?.id
                ?? (matched?.isComplete == true ? matched?.attempts.last?.id : nil)
            selectionUnavailable = false
        } else if let selectedAttemptID, matched?.attempts.contains(where: { $0.id == selectedAttemptID }) == true {
            selectionUnavailable = false
        } else {
            selectedAttemptID = nil
            selectionUnavailable = true
        }
        return true
    }

    mutating func select(_ id: String) {
        guard history?.attempts.contains(where: { $0.id == id }) == true else { return }
        selectedAttemptID = id
        followsLatestResult = false
        selectionUnavailable = false
    }

    var selectedAttempt: SettingsHistoryAttemptRecord? { history?.attempts.first { $0.id == selectedAttemptID } }
    var shownAttemptID: String? { selectedAttempt?.hasSavedText == true ? selectedAttemptID : nil }
    var emptyMessage: String? {
        if selectionUnavailable { return "This attempt is no longer available. Choose another attempt." }
        guard let attempt = selectedAttempt, !attempt.hasSavedText else { return nil }
        switch attempt.status {
        case .captured: return "No text from this attempt yet."
        case .transcribing, .formatting: return "This attempt is still running."
        case .failed: return "No text from this failed attempt."
        case .cancelled: return "No text from this cancelled attempt."
        case .timedOut: return "No text from this timed-out attempt."
        case .completed: return "No saved text is available for this attempt."
        }
    }

    func displayedEntry(_ entry: SettingsHistoryEntry) -> SettingsHistoryEntry {
        let text: String
        if entry.id != entryID || entry.audioPath.standardizedFileURL.path != recordingPath { text = "" }
        else if selectionUnavailable { text = "" }
        else if let attempt = selectedAttempt { text = attempt.savedText ?? "" }
        else if history?.isComplete == true { text = "" }
        else { return entry } // Legacy archive text has no invented attempt identity or Shown chip.
        return SettingsHistoryEntry(id: entry.id, dayKey: entry.dayKey, recordingID: entry.recordingID,
            createdAt: entry.createdAt, transcript: text, audioPath: entry.audioPath, durationMs: entry.durationMs,
            transcribedDurationMs: entry.transcribedDurationMs, spokenDurationMs: entry.spokenDurationMs,
            processingDurationMs: entry.processingDurationMs, micDisconnectedAtMs: entry.micDisconnectedAtMs,
            micDisconnectNote: entry.micDisconnectNote, modelLabel: entry.modelLabel,
            performanceEffort: entry.performanceEffort, inputDeviceLabel: entry.inputDeviceLabel,
            missingTranscript: nil)
    }
}
