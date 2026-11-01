import XCTest
@testable import VoiceBarUI

final class SettingsHistoryAttemptSelectionTests: XCTestCase {
    private let original = "Pack red. No, blue. Keep the fu… fragment and the tail.\n"
    private let final = "Pack red. No, blue. Keep the fu… fragment and the tail. Tomorrow too.\n"
    private func entry(_ id: String = "recording") -> SettingsHistoryEntry {
        .init(id: id, dayKey: "2026-11-01", recordingID: id, createdAt: .distantPast,
              transcript: "Archive text with no attempt identity", audioPath: URL(fileURLWithPath: "/fixture/\(id)/audio.wav"),
              durationMs: 32000, spokenDurationMs: 27000, micDisconnectNote: "Saved note", modelLabel: "Archive model")
    }
    private func history(_ status: SettingsHistoryAttemptRecord.Status = .completed, entry e: SettingsHistoryEntry? = nil) -> SettingsHistoryAttemptHistory {
        .init(recordingPath: (e ?? entry()).audioPath.path, attempts: [
            .init(id: "original", status: .completed, savedText: original),
            .init(id: "retry-1", status: .failed, failureReason: "Model unavailable"),
            .init(id: "retry-2", status: status, savedText: status == .completed ? final : nil)
        ], isComplete: true)
    }
    private func refresh(_ state: inout SettingsHistoryAttemptSelection, _ history: SettingsHistoryAttemptHistory?, entry e: SettingsHistoryEntry? = nil) {
        let token = state.beginRead()
        XCTAssertTrue(state.receive(history, entry: e ?? entry(), token: token))
    }
    private func copiedWords(_ displayed: SettingsHistoryEntry) -> String? {
        SettingsHistoryRowModel.recording(displayed).parts[0].actionableText
    }
    func testLatestCompletedResultIsOnlyADisplayDefaultAndOriginalRemainsExact() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        let log = history(); refresh(&state, log)
        XCTAssertEqual(state.shownAttemptID, "retry-2")
        XCTAssertEqual(state.displayedEntry(e).transcript, final)
        state.select("original")
        let displayed = state.displayedEntry(e)
        XCTAssertEqual(displayed.transcript, original)
        XCTAssertEqual(copiedWords(displayed), original)
        XCTAssertEqual(state.shownAttemptID, "original")
        XCTAssertEqual(displayed.audioPath, e.audioPath)
        XCTAssertEqual(displayed.spokenDurationMs, e.spokenDurationMs)
        XCTAssertEqual(displayed.micDisconnectNote, e.micDisconnectNote)
        XCTAssertEqual(state.history, log, "UI selection cannot mutate the STATE projection")
    }
    func testFailedRunningCancelledTimedOutHaveNoBorrowedWordsOrCopy() {
        for status: SettingsHistoryAttemptRecord.Status in [.failed, .transcribing, .formatting, .cancelled, .timedOut, .captured] {
            let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
            refresh(&state, history(status)); state.select("retry-2")
            XCTAssertEqual(state.displayedEntry(e).transcript, "")
            XCTAssertNil(copiedWords(state.displayedEntry(e)))
            XCTAssertNil(state.shownAttemptID)
            XCTAssertNotNil(state.emptyMessage)
            state.select("original")
            XCTAssertEqual(copiedWords(state.displayedEntry(e)), original, "saved original stays selectable")
        }
    }
    func testFailureThenRunningRetryThenFinishedBecomesShownWithoutSelectingOriginalAgain() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        let failed = history(); let firstTwo = SettingsHistoryAttemptHistory(recordingPath: e.audioPath.path,
            attempts: Array(failed.attempts.prefix(2)), isComplete: true)
        refresh(&state, firstTwo)
        XCTAssertEqual(state.shownAttemptID, "original")
        refresh(&state, history(.transcribing))
        XCTAssertEqual(state.shownAttemptID, "original")
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), original)
        refresh(&state, history())
        XCTAssertEqual(state.shownAttemptID, "retry-2")
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), final)
    }
    func testInnocentRefreshAndNewResultPreserveExplicitOriginalSelection() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, history(.transcribing)); state.select("original")
        refresh(&state, history(.transcribing)); refresh(&state, history())
        XCTAssertEqual(state.shownAttemptID, "original")
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), original)
        XCTAssertFalse(state.followsLatestResult)
    }
    func testSelectedRunningAttemptShowsItsOwnOutputWhenItFinishes() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, history(.transcribing)); state.select("retry-2")
        XCTAssertNil(copiedWords(state.displayedEntry(e)))
        refresh(&state, history())
        XCTAssertEqual(state.shownAttemptID, "retry-2")
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), final)
    }
    func testOlderAsyncRefreshCannotOverwriteNewerRefreshEvenWithoutCancellation() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        let stale = state.beginRead(); let current = state.beginRead()
        XCTAssertTrue(state.receive(history(), entry: e, token: current))
        XCTAssertFalse(state.receive(history(.transcribing), entry: e, token: stale))
        XCTAssertEqual(state.shownAttemptID, "retry-2")
    }
    func testRecordSwitchAndForeignReaderCannotCarryPriorAttemptText() {
        let e = entry(), other = entry("other"); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, history()); let token = state.beginRead()
        XCTAssertFalse(state.receive(history(entry: other), entry: other, token: token))
        XCTAssertNil(copiedWords(state.displayedEntry(other)))
        var newState = SettingsHistoryAttemptSelection(entry: other)
        refresh(&newState, history(), entry: other)
        XCTAssertNil(newState.history)
        XCTAssertNil(newState.shownAttemptID)
        XCTAssertEqual(copiedWords(newState.displayedEntry(other)), other.transcript, "legacy archive remains explicitly unattributed")
    }
    func testDisappearingSelectionFailsClosedUntilAnAvailableAttemptIsChosen() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, history()); state.select("original")
        let removed = SettingsHistoryAttemptHistory(recordingPath: e.audioPath.path,
            attempts: Array(history().attempts.dropFirst()), isComplete: true)
        refresh(&state, removed)
        XCTAssertTrue(state.selectionUnavailable)
        XCTAssertNil(copiedWords(state.displayedEntry(e)))
        XCTAssertNil(state.shownAttemptID)
        state.select("retry-2")
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), final)
    }
    func testDuplicateAttemptIdentityFailsClosed() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        let duplicate = SettingsHistoryAttemptHistory(recordingPath: e.audioPath.path,
            attempts: [.init(id: "same", status: .completed, savedText: original), .init(id: "same", status: .completed, savedText: final)], isComplete: true)
        refresh(&state, duplicate)
        XCTAssertNil(state.history); XCTAssertNil(copiedWords(state.displayedEntry(e)))
    }
    func testNilLegacyAndIncompleteHistoryNeverInventShownIdentity() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, nil)
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), e.transcript)
        XCTAssertNil(state.shownAttemptID)
        refresh(&state, .init(recordingPath: e.audioPath.path, attempts: [.init(id: "unresolved", status: .failed)], isComplete: false))
        XCTAssertEqual(copiedWords(state.displayedEntry(e)), e.transcript)
        XCTAssertNil(state.shownAttemptID)
    }
    func testCompactStatusContractAndNoRepeatedInstructions() {
        XCTAssertEqual(SettingsHistoryAttemptRecord.title(at: 0), "Original")
        XCTAssertEqual(SettingsHistoryAttemptRecord.title(at: 2), "Retry 2")
        let symbols: [(SettingsHistoryAttemptRecord.Status, String)] = [(.completed,"checkmark"),(.failed,"xmark"),(.cancelled,"slash.circle"),(.transcribing,"clock")]
        for (status, symbol) in symbols { XCTAssertEqual(SettingsHistoryAttemptRecord(id: "row", status: status).statusSymbol, symbol) }
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: nil, runs: [], omittedCount: 0, attemptHistory: history(), recordingID: entry().recordingID)
        XCTAssertTrue(copy.technicalDetails.contains("Recording ID: \(entry().recordingID)"))
        XCTAssertEqual(copy.summary, "")
        XCTAssertEqual(copy.visibleSentences, [SettingsHistoryDiagnosticsCopy.olderDetails])
        XCTAssertFalse(copy.defaultExpanded, "successful recordings remain collapsed even with multiple attempts")
        XCTAssertFalse(SettingsHistoryDiagnosticsCopy(snapshot: nil, runs: [], omittedCount: 0, attemptHistory: nil).defaultExpanded)
    }
    func testPartialFlagAndRetryEnablementRemainAuthoritative() {
        let e = entry(); var state = SettingsHistoryAttemptSelection(entry: e)
        refresh(&state, history()); state.select("original")
        let part = SettingsHistoryRowModel.recording(state.displayedEntry(e)).parts[0]
        for busy in [SettingsHistoryActionEnablement(isRetranscribing: true, isRecording: false, isTranscribing: false),
                     SettingsHistoryActionEnablement(isRetranscribing: false, isRecording: true, isTranscribing: false),
                     SettingsHistoryActionEnablement(isRetranscribing: false, isRecording: false, isTranscribing: true)] {
            XCTAssertFalse(busy.isEnabled(.retranscribe, for: part))
        }
        let partial = SettingsHistoryAttemptHistory(recordingPath: e.audioPath.path, attempts: [], isComplete: true, hasPartialResult: true)
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: nil, runs: [], omittedCount: 0, attemptHistory: partial)
        XCTAssertTrue(copy.shouldExpand); XCTAssertEqual(copy.statusChip, "Partial text")
    }
}
