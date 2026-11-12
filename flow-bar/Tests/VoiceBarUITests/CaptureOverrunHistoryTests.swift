@testable import VoiceBarUI
import XCTest

/// c8-M3 (RM-overrun P1): a take where macOS dropped microphone audio is never shown in History as a
/// complete transcript. The daemon writes `capture_overruns` and `capture_overrun_note`; the History row
/// shows the warning beside the lengths and History Details lists it.
final class CaptureOverrunHistoryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-overrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func writeTake(id: String, extra: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent("2026-11-11/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try "Synthetic fixture text".write(to: dir.appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        try """
        {
          "id": "\(id)",
          "created_at": "2026-11-11T21:34:53.186Z",
          "source": "voicebar",
          "duration_ms": 87600,
          "transcription_status": "transcribed"\(extra)
        }
        """.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        return dir.appendingPathComponent("audio.wav")
    }

    private static let note = "The system dropped audio during this take (4 times). The transcript may be missing words."

    func testHistoryRowShowsTheAudioLossWarning() throws {
        _ = try writeTake(id: "2026-11-11T21-34-53-186Z-0000aaaa", extra: """
        ,
          "capture_overruns": { "count": 4 },
          "capture_overrun_note": "\(Self.note)"
        """)
        let loaded = try XCTUnwrap(SettingsHistoryArchive.loadPage(from: tempRoot).groups.first?.entries.first)
        XCTAssertEqual(SettingsHistoryRowModel.recording(loaded).parts[0].audioLossLabel, Self.note)
    }

    func testHistoryDetailsListTheAudioLossWarning() throws {
        let audio = try writeTake(id: "2026-11-11T21-34-53-186Z-0000bbbb", extra: """
        ,
          "capture_overruns": { "count": 4 },
          "capture_overrun_note": "\(Self.note)"
        """)
        let details = SettingsHistoryDiagnostics.load(audioPath: audio, root: tempRoot)
        XCTAssertTrue(details.warnings.contains(Self.note), "\(details.warnings)")
    }

    func testCleanTakeShowsNoWarning() throws {
        let audio = try writeTake(id: "2026-11-11T21-34-53-186Z-0000cccc", extra: "")
        let loaded = try XCTUnwrap(SettingsHistoryArchive.loadPage(from: tempRoot).groups.first?.entries.first)
        XCTAssertNil(SettingsHistoryRowModel.recording(loaded).parts[0].audioLossLabel)
        let details = SettingsHistoryDiagnostics.load(audioPath: audio, root: tempRoot)
        XCTAssertFalse(details.warnings.contains { $0.contains("dropped audio") })
    }
}
