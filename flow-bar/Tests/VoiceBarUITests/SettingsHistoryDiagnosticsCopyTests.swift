import XCTest
@testable import VoiceBarUI

final class SettingsHistoryDiagnosticsCopyTests: XCTestCase {
    private let path = URL(fileURLWithPath: "/synthetic/2026-11-01/recording/audio.wav")
    private func snapshot(_ state: SettingsHistoryDiagnostics.ArchiveState = .transcribed) -> SettingsHistoryDiagnostics {
        .init(archiveState: state, savedTextState: .present, selection: "2026-11-01/recording",
              summary: "Archive reports a transcribed result", savedResult: "Saved transcript present; attempt identity unknown",
              capturedAt: nil, backend: nil, model: nil, detail: "Synthetic saved error",
              warnings: ["Earlier attempts and retry times are not retained in this archive format."])
    }
    func testSuccessfulSelectionStartsCollapsed() {
        XCTAssertFalse(SettingsHistoryDiagnosticsDisclosure(selection: "successful-recording").expanded)
    }
    func testOnlyFailureOrExplicitPartialAutoExpands() {
        let success = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: [], omittedCount: 0, attemptHistory: nil)
        XCTAssertFalse(success.shouldExpand)
        XCTAssertTrue(SettingsHistoryDiagnosticsCopy(snapshot: snapshot(.failed), runs: [], omittedCount: 0, attemptHistory: nil).shouldExpand)
        let partial = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [], isComplete: true, hasPartialResult: true)
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: [], omittedCount: 0, attemptHistory: partial)
        XCTAssertTrue(copy.shouldExpand)
        var disclosure = SettingsHistoryDiagnosticsDisclosure(selection: "same", defaultExpanded: false)
        disclosure.expanded = true
        disclosure.select("same", defaultExpanded: false)
        XCTAssertTrue(disclosure.expanded, "refresh preserves a deliberate expansion")
        disclosure.select("same", defaultExpanded: true)
        disclosure.select("same", defaultExpanded: false)
        XCTAssertFalse(disclosure.expanded, "a newly successful result returns to its quiet default")
    }
    func testMissingFactsBecomeOneQuietLineAndTechnicalCaveatsStayOutOfMainCopy() {
        var log = SettingsHistoryRunLog()
        for i in 0..<4 {
            log.begin(id: "technical-id-\(i)", path: path.path)
            log.observe(["type": "ack", "command": "retranscribe_recording", "id": "technical-id-\(i)", "outcome": "accept"])
        }
        log.observe(["type": "transcription", "recording_path": path.path, "text": "Synthetic words"])
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: log.runs, omittedCount: 0, attemptHistory: nil)
        XCTAssertEqual(copy.visibleSentences.filter { $0 == SettingsHistoryDiagnosticsCopy.olderDetails }.count, 1)
        let main = copy.visibleSentences.joined(separator: " ")
        for forbidden in ["unknown", "attributed", "backend", "archive write", "technical-id-", "observation times"] {
            XCTAssertFalse(main.contains(forbidden), forbidden)
        }
        XCTAssertTrue(copy.technicalDetails.contains("cannot be attributed"))
        XCTAssertTrue(copy.technicalDetails.contains("attempt identity unknown"))
        XCTAssertTrue(copy.technicalDetails.contains("technical-id-3"))
        XCTAssertFalse(SettingsHistoryDiagnosticsDisclosure(selection: "recording").detailsExpanded)
    }
    func testCompleteStateHistoryReplacesProvisionalRequestAndMissingDetailsNotice() async throws {
        let expected = SettingsHistoryAttemptHistory(recordingPath: path.path,
            attempts: [.init(id: "attempt-1", status: .failed), .init(id: "attempt-2", status: .completed)], isComplete: true)
        let reader: SettingsHistoryAttemptLogReader = { url in expected.matching(url) }
        let loaded = await reader(path)
        let history = try XCTUnwrap(loaded)
        var log = SettingsHistoryRunLog(); log.begin(id: "provisional", path: path.path)
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: log.runs, omittedCount: 0, attemptHistory: history)
        XCTAssertNil(copy.latestUpdate)
        XCTAssertEqual(copy.olderNotice, SettingsHistoryDiagnosticsCopy.olderDetails, "complete attempts without execution metrics keep one quiet notice")
        XCTAssertEqual(copy.attempts.map(\.id), ["attempt-1", "attempt-2"])
        XCTAssertEqual(copy.attempts[0].statusTitle, "Failed")
        XCTAssertEqual(copy.attempts[1].statusTitle, "Finished")
        XCTAssertTrue(copy.summary.isEmpty)
        XCTAssertFalse(copy.visibleSentences.joined().contains("provisional"))
    }
    func testRecordingErrorIsVisibleWithoutInventingARequestFailure() {
        var log = SettingsHistoryRunLog(); log.begin(id: "current", path: path.path)
        log.observe(["type": "error", "message": "Could not retranscribe archived recording \(path.path). Synthetic decoder failure"])
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: log.runs, omittedCount: 0, attemptHistory: nil)
        XCTAssertEqual(log.runs[0].outcome, .unknown)
        XCTAssertTrue(copy.latestUpdate?.contains("reported a problem with this recording") == true)
        XCTAssertTrue(copy.technicalDetails.contains("attribution to this request is unavailable"))
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "current", "outcome": "reject", "reason": "Synthetic exact rejection"])
        let rejected = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(), runs: log.runs, omittedCount: 0, attemptHistory: nil)
        XCTAssertTrue(rejected.latestUpdate?.contains("couldn't start this retry") == true)
    }
    func testReaderCannotAttachAnotherRecordingsAttempts() {
        let history = SettingsHistoryAttemptHistory(recordingPath: "/other/recording/audio.wav",
            attempts: [.init(id: "foreign", status: .completed)], isComplete: true)
        XCTAssertNil(history.matching(path))
    }
    func testFailureKeepsSavedWordsAndOffersOneClearAction() {
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot(.failed), runs: [], omittedCount: 0, attemptHistory: nil)
        XCTAssertTrue(copy.summary.contains("Saved text is still available"))
        XCTAssertFalse(copy.summary.contains("read or copy"), "remove filler; the transcript is already visible")
        XCTAssertEqual(copy.visibleSentences.count, 2, "one useful summary plus one quiet missing-details line")
    }
}
