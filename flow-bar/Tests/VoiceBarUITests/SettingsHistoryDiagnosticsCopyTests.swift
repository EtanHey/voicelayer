import XCTest
@testable import VoiceBarUI

final class SettingsHistoryDiagnosticsCopyTests: XCTestCase {
    private let path = URL(fileURLWithPath: "/synthetic/2026-11-01/recording/audio.wav")
    private let locale = Locale(identifier: "en_US")
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let created = Date(timeIntervalSince1970: 1_793_000_000)
    /// Archive vocabulary Etan ruled off the screen (2026-11-02 QA). It may survive only in the copied Log.
    private let jargon = ["Archive", "archive", "attempt identity", "unknown", "Earlier attempts", "format",
                          "per-recording", "backend", "attributed", "Technical details", "Older details", "technical-id-"]

    private func snapshot(_ state: SettingsHistoryDiagnostics.ArchiveState = .transcribed, backend: String? = nil,
                          language: String? = nil, mic: String? = nil) -> SettingsHistoryDiagnostics {
        .init(archiveState: state, savedTextState: .present, selection: "2026-11-01/recording",
              summary: "Archive reports a transcribed result", savedResult: "Saved transcript present; attempt identity unknown",
              capturedAt: nil, backend: backend, model: nil, detail: "Synthetic saved error",
              warnings: ["Earlier attempts and retry times are not retained in this archive format."],
              languageSetting: language, inputDeviceName: mic)
    }
    private func entry(processingMs: Int? = 900, model: String? = nil) -> SettingsHistoryEntry {
        .init(id: "recording", dayKey: "2026-11-01", recordingID: "rec-123", createdAt: created,
              transcript: "Pack red. No, blue. Keep the fu… fragment.", audioPath: path,
              durationMs: 19_800, processingDurationMs: processingMs, modelLabel: model)
    }
    private func copy(_ snapshot: SettingsHistoryDiagnostics?, runs: [SettingsHistoryRunLog.Run] = [],
                      history: SettingsHistoryAttemptHistory? = nil, entry: SettingsHistoryEntry? = nil) -> SettingsHistoryDiagnosticsCopy {
        SettingsHistoryDiagnosticsCopy(snapshot: snapshot, runs: runs, omittedCount: 0, attemptHistory: history,
                                       recordingID: "rec-123", recordingEntry: entry, locale: locale, timeZone: utc)
    }
    private func visibleText(_ copy: SettingsHistoryDiagnosticsCopy, facts: [SettingsHistoryFact] = []) -> String {
        (copy.visibleSentences + copy.logLines.map(\.text) + facts.flatMap { [$0.title, $0.value] }).joined(separator: "\n")
    }
    private func clock(_ date: Date) -> String { SettingsHistoryDiagnosticsCopy.clockTime(date, locale: locale, timeZone: utc) }

    func testSuccessfulSelectionStartsCollapsed() {
        XCTAssertFalse(SettingsHistoryDiagnosticsDisclosure(selection: "successful-recording").expanded)
    }
    func testOnlyFailureOrExplicitPartialAutoExpands() {
        XCTAssertFalse(copy(snapshot()).shouldExpand)
        XCTAssertTrue(copy(snapshot(.failed)).shouldExpand)
        let partial = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [], isComplete: true, hasPartialResult: true)
        XCTAssertTrue(copy(snapshot(), history: partial).shouldExpand)
        var disclosure = SettingsHistoryDiagnosticsDisclosure(selection: "same", defaultExpanded: false)
        disclosure.expanded = true
        disclosure.select("same", defaultExpanded: false)
        XCTAssertTrue(disclosure.expanded, "refresh preserves a deliberate expansion")
        disclosure.select("same", defaultExpanded: true)
        disclosure.select("same", defaultExpanded: false)
        XCTAssertFalse(disclosure.expanded, "a newly successful result returns to its quiet default")
    }

    /// Etan, 2026-11-02: "I don't know why older details weren't saved for this recording when this
    /// recording was just recorded now." Missing optional fields and an absent reader are not evidence.
    func testFreshTakeNeverClaimsMissingHistory() {
        let fresh = copy(snapshot(), entry: entry(processingMs: nil))
        XCTAssertNil(fresh.notice, "no language, mic, engine, duration or attempt reader is still a complete fresh take")
        XCTAssertEqual(fresh.visibleSentences, [])
        XCTAssertNil(copy(nil, entry: entry()).notice, "a snapshot still loading is not missing history")
        let bare = SettingsHistoryAttemptHistory(recordingPath: path.path,
            attempts: [.init(id: "only", status: .completed, savedText: "Exact words.")], isComplete: true)
        XCTAssertNil(copy(snapshot(), history: bare).notice, "a complete log without execution fields is complete")
    }
    func testOnlyActuallyIncompleteDataGetsOnePlainNotice() {
        let legacy = copy(snapshot(.unavailable), entry: entry())
        XCTAssertEqual(legacy.notice, SettingsHistoryDiagnosticsCopy.incompleteDetails)
        XCTAssertEqual(legacy.visibleSentences.filter { $0 == SettingsHistoryDiagnosticsCopy.incompleteDetails }.count, 1)
        XCTAssertTrue(legacy.logLines.isEmpty, "an archive with no established outcome gets no invented Log row")
        let incomplete = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [.init(id: "late", status: .completed)], isComplete: false)
        XCTAssertEqual(copy(snapshot(), history: incomplete).notice, SettingsHistoryDiagnosticsCopy.incompleteAttempts)
        let complete = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [.init(id: "a", status: .completed)], isComplete: true)
        XCTAssertNil(copy(snapshot(.unavailable), history: complete).notice, "the reader's own completeness governs when it is supplied")
        for notice in [SettingsHistoryDiagnosticsCopy.incompleteDetails, SettingsHistoryDiagnosticsCopy.incompleteAttempts] {
            for word in jargon { XCTAssertFalse(notice.contains(word), "\(word) in \(notice)") }
        }
    }

    func testFreshTakeLogIsOneRowWithItsTimeAndProcessing() {
        let lines = copy(snapshot(), entry: entry()).logLines
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].source, .archivedTake)
        XCTAssertEqual(lines[0].title, "Original")
        XCTAssertEqual(lines[0].time, clock(created), "the take's own capture time, local")
        XCTAssertEqual(lines[0].outcome, "Finished")
        XCTAssertEqual(lines[0].processing, "processed in 0.9 s")
        XCTAssertFalse(lines[0].isProblem)
        XCTAssertNil(copy(snapshot(), entry: entry(processingMs: nil)).logLines[0].processing, "no measurement, no number")
        let cancelled = copy(snapshot(.cancelled), entry: entry())
        XCTAssertEqual(cancelled.logLines.map(\.outcome), ["Cancelled"])
        XCTAssertEqual(cancelled.summary, "", "the Log row already says Cancelled")
    }
    func testSessionRetriesAppendUnnumberedRowsWithoutInventedProcessing() {
        let first = created.addingTimeInterval(60), second = created.addingTimeInterval(120)
        var log = SettingsHistoryRunLog()
        log.begin(id: "r1", path: path.path, at: first)
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "r1", "outcome": "accept"])
        log.begin(id: "r2", path: path.path, at: second)
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "r2", "outcome": "reject", "reason": "Busy"])
        log.observe(["type": "transcription", "recording_path": path.path, "text": "Synthetic words"])
        let lines = copy(snapshot(), runs: log.runs, entry: entry()).logLines
        XCTAssertEqual(lines.map(\.title), ["Original", "Retry", "Retry"], "earlier sessions' retries are unknown, so no numbering")
        XCTAssertEqual(lines.map(\.time), [clock(created), clock(first), clock(second)], "oldest first")
        XCTAssertEqual(lines.map(\.outcome), ["Finished", "New text received", "Couldn't start"])
        XCTAssertEqual(lines.dropFirst().map(\.processing), [nil, nil], "observation times are never shown as processing")
    }
    func testRecordingErrorIsVisibleWithoutInventingARequestFailure() {
        var log = SettingsHistoryRunLog(); log.begin(id: "current", path: path.path, at: created)
        log.observe(["type": "error", "message": "Could not retranscribe archived recording \(path.path). Synthetic decoder failure"])
        let reported = copy(snapshot(), runs: log.runs)
        XCTAssertEqual(log.runs[0].outcome, .unknown)
        XCTAssertEqual(reported.logLines.last?.outcome, "Problem reported")
        XCTAssertTrue(reported.logLines.last?.isProblem == true)
        XCTAssertTrue(reported.shouldExpand)
        XCTAssertTrue(reported.logCopyText.contains("attribution to this request is unavailable"))
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "current", "outcome": "reject", "reason": "Synthetic exact rejection"])
        XCTAssertEqual(copy(snapshot(), runs: log.runs).logLines.last?.outcome, "Couldn't start")
    }

    func testJargonStaysOffScreenButProvenanceIsCopyable() {
        var log = SettingsHistoryRunLog()
        for i in 0..<4 {
            log.begin(id: "technical-id-\(i)", path: path.path)
            log.observe(["type": "ack", "command": "retranscribe_recording", "id": "technical-id-\(i)", "outcome": "accept"])
        }
        log.observe(["type": "transcription", "recording_path": path.path, "text": "Synthetic words"])
        let shot = snapshot(backend: "parakeet-resident", language: "auto", mic: "Desk microphone")
        let result = copy(shot, runs: log.runs, entry: entry())
        let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: shot, entry: entry(), attemptHistory: nil, selectedAttemptID: nil)
        let visible = visibleText(result, facts: facts)
        for word in jargon { XCTAssertFalse(visible.contains(word), word) }
        for kept in ["Recording ID: rec-123", "attempt identity unknown", "technical-id-3", "cannot be attributed",
                     "Backend: parakeet-resident", "Processing duration (ms): 900"] {
            XCTAssertTrue(result.logCopyText.contains(kept), kept)
        }
        XCTAssertFalse(result.logCopyText.contains("Archive backend"), "plain labels even in the copy")
    }

    func testEngineSitsBesideLanguageAndDateAndAudioAreNotRepeated() {
        let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: snapshot(backend: "parakeet-resident", language: "auto", mic: "Desk microphone"),
                                                         entry: entry(), attemptHistory: nil, selectedAttemptID: nil)
        XCTAssertEqual(facts.map(\.title), ["Microphone", "Language setting", "Engine"])
        XCTAssertEqual(facts.map(\.value), ["Desk microphone", "auto", "Parakeet"])
        for duplicate in ["Created", "Audio length", "Processing", "Recording ID"] {
            XCTAssertFalse(facts.map(\.title).contains(duplicate), "\(duplicate) is shown once elsewhere")
        }
        let names: [(String?, String?)] = [("parakeet-resident", "Parakeet"), ("whisper-server+outro", "Whisper"),
            ("whisper.cpp", "Whisper"), ("wispr-flow", "Wispr Flow"), ("fake-stt", nil), ("", nil), (nil, nil)]
        for (raw, name) in names { XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineName(raw), name, raw ?? "nil") }
        let legacy = SettingsHistoryDiagnosticsCopy.facts(snapshot: snapshot(backend: "whisper-server"), entry: entry(model: "large-v3-turbo"),
                                                          attemptHistory: nil, selectedAttemptID: nil)
        XCTAssertEqual(legacy.map(\.title), ["Engine", "Model"])
    }
    func testAttemptFactsAreAttemptLocalAndLastTranscribedOnlyAfterACompletedRetry() {
        let t0 = created, t1 = created.addingTimeInterval(300)
        let retried = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [
            .init(id: "original", status: .completed, startedAt: t0, savedText: "A.", engine: "parakeet-resident", processingDurationMs: 400),
            .init(id: "retry-1", status: .completed, startedAt: t1, savedText: "B.", engine: "whisper.cpp", model: "large-v3", processingDurationMs: 2750)
        ], isComplete: true)
        let shot = snapshot(backend: "parakeet-resident")
        func facts(_ history: SettingsHistoryAttemptHistory, _ selected: String?) -> [SettingsHistoryFact] {
            SettingsHistoryDiagnosticsCopy.facts(snapshot: shot, entry: entry(model: "Archive model"), attemptHistory: history,
                                                 selectedAttemptID: selected, locale: locale, timeZone: utc)
        }
        XCTAssertEqual(facts(retried, "original").first { $0.title == "Engine" }?.value, "Parakeet")
        XCTAssertEqual(facts(retried, nil).first { $0.title == "Engine" }?.value, "Whisper", "unselected follows the latest attempt")
        XCTAssertEqual(facts(retried, nil).first { $0.title == "Last transcribed" }?.value,
                       SettingsHistoryDiagnosticsCopy.dateTime(t1, locale: locale, timeZone: utc))
        XCTAssertFalse(facts(retried, nil).contains { $0.value == "Archive model" }, "archive settings never stand in for an attempt's")
        let lines = copy(shot, history: retried).logLines
        XCTAssertEqual(lines.map(\.processing), ["processed in 0.4 s", "processed in 2.8 s"], "per-attempt processing is in the Log")
        XCTAssertEqual(lines.map(\.time), [clock(t0), clock(t1)])

        let single = SettingsHistoryAttemptHistory(recordingPath: path.path, attempts: [retried.attempts[0]], isComplete: true)
        XCTAssertFalse(facts(single, nil).contains { $0.title == "Last transcribed" }, "never retranscribed")
        let failedRetry = SettingsHistoryAttemptHistory(recordingPath: path.path,
            attempts: [retried.attempts[0], .init(id: "retry-1", status: .failed, startedAt: t1)], isComplete: true)
        XCTAssertFalse(facts(failedRetry, nil).contains { $0.title == "Last transcribed" }, "a failed retry did not transcribe it again")
        XCTAssertFalse(facts(failedRetry, "retry-1").contains { $0.title == "Engine" },
                       "an attempt with no reported engine shows none; the archive backend is not borrowed")
    }

    func testCompleteStateHistoryReplacesProvisionalRequests() async throws {
        let expected = SettingsHistoryAttemptHistory(recordingPath: path.path,
            attempts: [.init(id: "attempt-1", status: .failed), .init(id: "attempt-2", status: .completed)], isComplete: true)
        let reader: SettingsHistoryAttemptLogReader = { url in expected.matching(url) }
        let loaded = await reader(path)
        let history = try XCTUnwrap(loaded)
        var log = SettingsHistoryRunLog(); log.begin(id: "provisional", path: path.path)
        let result = copy(snapshot(), runs: log.runs, history: history, entry: entry())
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.attempts.map(\.id), ["attempt-1", "attempt-2"])
        XCTAssertEqual(result.logLines.map(\.attemptID), ["attempt-1", "attempt-2"], "no archive or session row duplicates durable attempts")
        XCTAssertEqual(result.logLines.map(\.outcome), ["Failed", "Finished"])
        XCTAssertTrue(result.summary.isEmpty)
        XCTAssertFalse(visibleText(result).contains("provisional"))
    }
    func testReaderCannotAttachAnotherRecordingsAttempts() {
        let history = SettingsHistoryAttemptHistory(recordingPath: "/other/recording/audio.wav",
            attempts: [.init(id: "foreign", status: .completed)], isComplete: true)
        XCTAssertNil(history.matching(path))
    }
    func testFailureKeepsSavedWordsAndOffersOneClearAction() {
        let result = copy(snapshot(.failed), entry: entry())
        XCTAssertTrue(result.summary.contains("Saved text is still available"))
        XCTAssertFalse(result.summary.contains("read or copy"), "remove filler; the transcript is already visible")
        XCTAssertEqual(result.visibleSentences.count, 1, "one useful summary; a failure is not missing history")
        XCTAssertEqual(result.logLines.map(\.outcome), ["Failed"])
        XCTAssertTrue(result.logLines[0].isProblem)
    }
}
