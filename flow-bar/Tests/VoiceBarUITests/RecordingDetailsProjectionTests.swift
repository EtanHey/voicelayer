import XCTest
@testable import VoiceBarUI
final class RecordingDetailsProjectionTests: XCTestCase {
    func testOptionalExecutionFactsStayAttemptLocalAndBounded() {
        let absent = SettingsHistoryAttemptRecord(id: "legacy", status: .completed)
        XCTAssertNil(absent.executionLabel); XCTAssertNil(absent.processingLabel)
        let actual = SettingsHistoryAttemptRecord(id: "retry", status: .completed, startedAt: Date(timeIntervalSince1970: 0),
            engine: "whisper.cpp", model: "large-v3", effort: "Accurate", audioDurationMs: 32000, processingDurationMs: 2750)
        XCTAssertEqual(actual.executionLabel, "whisper.cpp · large-v3 · Effort: Accurate")
        XCTAssertEqual(actual.processingLabel, "processed in 2.8 s", "per-attempt processing only; audio length lives in the footer")
        let invalid = SettingsHistoryAttemptRecord(id: "invalid", status: .failed, engine: "  ", model: String(repeating: "x", count: 200), audioDurationMs: -1, processingDurationMs: -10)
        XCTAssertNil(invalid.engine); XCTAssertEqual(invalid.model?.count, 80); XCTAssertNil(invalid.processingLabel)
    }
    func testLocalWhenUsesFoundationCurrentAndSupportsDifferentZones() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T10:02:00Z"))
        let row = SettingsHistoryAttemptRecord(id: "retry", status: .failed, startedAt: date)
        let locale = Locale(identifier: "en_US")
        let format = DateFormatter(); format.locale = locale; format.timeZone = .current; format.timeStyle = .short
        XCTAssertEqual(row.localTimestamp(locale: locale), format.string(from: date))
        XCTAssertNotEqual(row.localTimestamp(locale: locale, timeZone: TimeZone(identifier: "Asia/Jerusalem")!), row.localTimestamp(locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!))
    }
    func testEveryAttemptSurvivesSessionLogLimitAndSuccessIsCollapsed() {
        let rows = (0..<45).map { SettingsHistoryAttemptRecord(id: "attempt-\($0)", status: .completed) }
        let history = SettingsHistoryAttemptHistory(recordingPath: "/synthetic/audio.wav", attempts: rows, isComplete: true)
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: nil, runs: [], omittedCount: 80, attemptHistory: history)
        XCTAssertEqual(copy.attempts.count, 45); XCTAssertFalse(copy.defaultExpanded)
        XCTAssertEqual(copy.logLines.count, 45, "every attempt keeps its own Log row past the session-request limit")
        XCTAssertNil(copy.notice, "attempts without execution metrics are not evidence of missing history")
        let failed = SettingsHistoryAttemptHistory(recordingPath: history.recordingPath, attempts: rows + [.init(id: "failed", status: .failed)], isComplete: true)
        XCTAssertTrue(SettingsHistoryDiagnosticsCopy(snapshot: nil, runs: [], omittedCount: 0, attemptHistory: failed).defaultExpanded)
    }
    func testStoredLanguageSettingAndMicrophoneMappingDoesNotUseDetectedOrCurrent() throws {
        guard let path = ProcessInfo.processInfo.environment["RECORDING_DETAILS_QA_ROOT"] else { throw XCTSkip("Set owned RECORDING_DETAILS_QA_ROOT for bounded archive fixture writes") }
        let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("2026-11-01/recording")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["id": "recording", "transcription_status": "transcribed", "language_mode": "auto", "detected_language": "Hebrew", "input_device_name": "Desk microphone"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: entry.appendingPathComponent("metadata.json"))
        let snapshot = SettingsHistoryDiagnostics.load(audioPath: entry.appendingPathComponent("audio.wav"), root: root)
        XCTAssertEqual(snapshot.languageSetting, "auto"); XCTAssertEqual(snapshot.inputDeviceName, "Desk microphone")
        let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: snapshot, entry: nil, attemptHistory: nil, selectedAttemptID: nil)
        XCTAssertTrue(facts.contains { $0.title == "Microphone" && $0.value == "Desk microphone" })
        try JSONSerialization.data(withJSONObject: ["detected_language": "Hebrew"]).write(to: entry.appendingPathComponent("metadata.json"))
        let legacy = SettingsHistoryDiagnostics.load(audioPath: entry.appendingPathComponent("audio.wav"), root: root)
        XCTAssertNil(legacy.languageSetting); XCTAssertNil(legacy.inputDeviceName)
        XCTAssertFalse(SettingsHistoryDiagnosticsCopy.facts(snapshot: legacy, entry: nil, attemptHistory: nil, selectedAttemptID: nil)
            .contains { $0.title == "Microphone" })
    }
}
