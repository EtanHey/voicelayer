import XCTest
@testable import VoiceBarUI
final class RecordingDetailsProjectionTests: XCTestCase {
    func testBuildTagSurvivesHistoryReloadAndRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("2026-11-08/recording")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let build: [String: Any] = ["version": "2.3.0", "git_commit": String(repeating: "a", count: 40),
            "build_time_utc": "2026-11-08T00:00:00Z", "source": "VoiceBar.Info.plist"]
        try JSONSerialization.data(withJSONObject: ["id": "recording", "source": "voicebar", "app_build": build,
            "retranscribed_by": ["version": "2.3.1", "git_commit": String(repeating: "b", count: 40)]]).write(to: directory.appendingPathComponent("metadata.json"))
        try Data().write(to: directory.appendingPathComponent("audio.wav"))
        let entry = try XCTUnwrap(SettingsHistoryArchive.load(from: root).first?.entries.first)
        let snapshot = SettingsHistoryDiagnostics.load(audioPath: entry.audioPath, root: root)
        for state in [snapshot, nil] {
            let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: state, entry: entry, attemptHistory: nil, selectedAttemptID: nil)
            XCTAssertTrue(facts.contains { $0.title == "Built from" && $0.value == "2.3.0 · aaaaaaaa" })
            XCTAssertTrue(facts.contains { $0.title == "Re-transcribed by" && $0.value == "2.3.1 · bbbbbbbb" })
        }
    }
    func testUnknownBuildAndAskRowLabelsUseOnlyStoredFacts() throws {
        let unknown = try JSONDecoder().decode(RecordingAppBuild.self, from: Data(#"{"version":null,"git_commit":null,"build_time_utc":null,"source":null}"#.utf8))
        XCTAssertNil(unknown.label)
        let build = try JSONDecoder().decode(RecordingAppBuild.self, from: Data(#"{"version":"2.3.0","git_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8))
        let entry = SettingsAskHistoryEntry(id: "fixture", dayKey: "2026-11-08", askID: "fixture", createdAt: Date(),
            questionText: "", questionAudioPath: nil, responseTranscript: "", responseAudioPath: nil,
            appBuild: build, retranscribedBy: unknown)
        let row = SettingsHistoryRowModel.ask(entry)
        XCTAssertEqual(row.buildLabel, "2.3.0 · aaaaaaaa")
        let unknownEntry = SettingsAskHistoryEntry(id: "unknown", dayKey: "2026-11-08", askID: "unknown", createdAt: Date(),
            questionText: "", questionAudioPath: nil, responseTranscript: "", responseAudioPath: nil, appBuild: unknown)
        XCTAssertNil(SettingsHistoryRowModel.ask(unknownEntry).buildLabel)
        let unknownRecording = SettingsHistoryEntry(id: "unknown", dayKey: "2026-11-08", recordingID: "unknown", createdAt: Date(),
            transcript: "", audioPath: URL(fileURLWithPath: "/synthetic/audio.wav"), appBuild: unknown)
        XCTAssertFalse(SettingsHistoryDiagnosticsCopy.facts(snapshot: nil, entry: unknownRecording, attemptHistory: nil, selectedAttemptID: nil)
            .contains { $0.title == "Built from" })
    }
    func testDirtyCheckoutAndFirstTranscriberAppearOnlyInDetails() throws {
        let build = try JSONDecoder().decode(RecordingAppBuild.self, from: Data(#"{"version":"2.3.0","git_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","git_describe":"v2.3.0-dirty","daemon_source":"checkout"}"#.utf8))
        XCTAssertEqual(build.label, "2.3.0 · aaaaaaaa (dirty, checkout)")
        let entry = SettingsHistoryEntry(id: "fixture", dayKey: "2026-11-08", recordingID: "fixture", createdAt: Date(),
            transcript: "", audioPath: URL(fileURLWithPath: "/synthetic/audio.wav"), appBuild: build, transcribedBy: build)
        let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: nil, entry: entry, attemptHistory: nil, selectedAttemptID: nil)
        XCTAssertTrue(facts.contains { $0.title == "Transcribed by" }); XCTAssertFalse(facts.contains { $0.title == "Re-transcribed by" })
        XCTAssertTrue(facts.contains { $0.title == "Build daemon source" && $0.value == "checkout" })
        XCTAssertTrue(facts.contains { $0.title == "Build description" && $0.value == "v2.3.0-dirty" })
        XCTAssertTrue(facts.contains { $0.title == "Build commit" && $0.value == String(repeating: "a", count: 40) })
    }
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
