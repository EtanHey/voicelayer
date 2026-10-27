@testable import VoiceBarUI
import XCTest

/// F1 (Etan, 2.2.26): each History dictation shows its processing time, and recorded vs ≈ spoken length so big
/// pauses are visible. No third number: when spoken length exists it replaces the trimmed length, which stays
/// only for entries archived before spoken length was measured.
final class SettingsHistoryTimingTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-timing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func entry(
        durationMs: Int? = 43400,
        transcribedDurationMs: Int? = 40100,
        spokenDurationMs: Int? = nil,
        processingDurationMs: Int? = nil
    ) -> SettingsHistoryEntry {
        SettingsHistoryEntry(
            id: "/tmp/timing/audio.wav",
            dayKey: "2026-09-27",
            recordingID: "timing",
            createdAt: Date(timeIntervalSince1970: 0),
            transcript: "Synthetic fixture text",
            audioPath: URL(fileURLWithPath: "/tmp/timing/audio.wav"),
            durationMs: durationMs,
            transcribedDurationMs: transcribedDurationMs,
            spokenDurationMs: spokenDurationMs,
            processingDurationMs: processingDurationMs
        )
    }

    func testArchiveMetadataCarriesSpokenAndProcessingTimes() throws {
        let dir = tempRoot.appendingPathComponent("2026-09-27/2026-09-27T10-00-00-000Z-timing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try "Synthetic fixture text".write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8
        )
        try """
        {
          "id": "2026-09-27T10-00-00-000Z-timing",
          "created_at": "2026-09-27T10:00:00.000Z",
          "source": "voicebar",
          "duration_ms": 43400,
          "transcribed_duration_ms": 40100,
          "spoken_duration_ms": 30250,
          "processing_duration_ms": 1234,
          "transcription_status": "transcribed"
        }
        """.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(SettingsHistoryArchive.loadPage(from: tempRoot).groups.first?.entries.first)

        XCTAssertEqual(loaded.spokenDurationMs, 30250)
        XCTAssertEqual(loaded.processingDurationMs, 1234)
    }

    /// MICDROP2: a recording cut short by a lost mic says so, and where, beside its lengths.
    func testMicDisconnectNoteLoadsFromMetadataAndShowsOnTheRow() throws {
        let dir = tempRoot.appendingPathComponent("2026-10-19/2026-10-19T03-31-00-000Z-drop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try """
        {
          "id": "2026-10-19T03-31-00-000Z-drop",
          "created_at": "2026-10-19T03:31:00.000Z",
          "source": "voicebar",
          "duration_ms": 42400,
          "mic_disconnected_at_ms": 42400,
          "mic_disconnect_reason": "device-removed",
          "mic_disconnect_note": "Mic disconnected at 0:42",
          "transcription_status": "captured"
        }
        """.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(SettingsHistoryArchive.loadPage(from: tempRoot).groups.first?.entries.first)
        XCTAssertEqual(loaded.micDisconnectedAtMs, 42400)

        XCTAssertEqual(SettingsHistoryRowModel.recording(loaded).parts[0].micDisconnectLabel, "Mic disconnected at 0:42")
        XCTAssertNil(SettingsHistoryRowModel.recording(entry()).parts[0].micDisconnectLabel)
    }

    /// A recorder that never carried signal has no loss point: its note, never a "0:00".
    func testNoSignalNoteShowsWithoutAClock() {
        var noSignal = SettingsHistoryEntry(
            id: "/tmp/nosig/audio.wav", dayKey: "2026-10-19", recordingID: "nosig",
            createdAt: Date(timeIntervalSince1970: 0), transcript: "",
            audioPath: URL(fileURLWithPath: "/tmp/nosig/audio.wav"),
            micDisconnectedAtMs: nil, micDisconnectNote: "Mic produced no signal"
        )
        XCTAssertEqual(SettingsHistoryRowModel.recording(noSignal).parts[0].micDisconnectLabel, "Mic produced no signal")
        noSignal = SettingsHistoryEntry(
            id: "/tmp/old/audio.wav", dayKey: "2026-10-19", recordingID: "old",
            createdAt: Date(timeIntervalSince1970: 0), transcript: "",
            audioPath: URL(fileURLWithPath: "/tmp/old/audio.wav"), micDisconnectedAtMs: 42400
        )
        XCTAssertEqual(SettingsHistoryRowModel.recording(noSignal).parts[0].micDisconnectLabel, "Mic disconnected at 0:42")
    }

    func testSpokenLengthReplacesTheTrimmedLengthAndProcessingSitsBesideThem() {
        let part = SettingsHistoryRowModel.recording(
            entry(spokenDurationMs: 30250, processingDurationMs: 1234)
        ).parts[0]

        XCTAssertEqual(part.durationLabel, "0:43")
        XCTAssertEqual(part.spokenDurationLabel, "0:30")
        XCTAssertNil(part.transcribedDurationLabel, "no third number once spoken length exists")
        XCTAssertEqual(part.processingLabel, "1.2 s processing")
    }

    func testOldEntriesKeepTheTrimmedLengthAndShowNoProcessing() {
        let part = SettingsHistoryRowModel.recording(entry()).parts[0]

        XCTAssertEqual(part.durationLabel, "0:43")
        XCTAssertEqual(part.transcribedDurationLabel, "0:40")
        XCTAssertNil(part.spokenDurationLabel)
        XCTAssertNil(part.processingLabel)
    }

    func testSpokenLengthWithinASecondOfTheRecordingIsNotRepeated() {
        let part = SettingsHistoryRowModel.recording(
            entry(transcribedDurationMs: 43400, spokenDurationMs: 42900, processingDurationMs: 800)
        ).parts[0]

        XCTAssertNil(part.spokenDurationLabel)
        XCTAssertNil(part.transcribedDurationLabel)
        XCTAssertEqual(part.processingLabel, "0.8 s processing")
    }

    func testRowStatsNameTheEstimateAndEveryTimeForVoiceOver() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func historyMediaPartStats"))
        let end = try XCTUnwrap(source.range(
            of: "private func historyMediaPartActions",
            range: start.upperBound ..< source.endIndex
        ))
        let stats = source[start.lowerBound ..< end.lowerBound]

        XCTAssertTrue(stats.contains("part.spokenDurationLabel"))
        XCTAssertTrue(stats.contains("part.processingLabel"))
        XCTAssertTrue(stats.contains("Spoken: speech time without pauses, estimated"), "the spoken tooltip names the estimate")
        XCTAssertTrue(stats.contains(".accessibilityLabel(\"Spoken length about"))
        XCTAssertTrue(stats.contains(".accessibilityLabel(\"Processing time"))
    }
}
