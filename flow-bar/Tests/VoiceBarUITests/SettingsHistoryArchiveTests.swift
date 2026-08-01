@testable import VoiceBarUI
import XCTest

final class SettingsHistoryArchiveTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicelayer-settings-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testLoadsRecordingsGroupedByDiskDayNewestToOldest() throws {
        try writeRecording(
            day: "2026-06-23",
            id: "2026-06-23T18-45-00-000Z-old",
            createdAt: "2026-06-23T18:45:00.000Z",
            transcript: "Eitan was misheard in the old clip"
        )
        try writeRecording(
            day: "2026-06-25",
            id: "2026-06-25T07-05-00-000Z-first",
            createdAt: "2026-06-25T07:05:00.000Z",
            transcript: "Morning clip"
        )
        try writeRecording(
            day: "2026-06-25",
            id: "2026-06-25T21-30-00-000Z-latest",
            createdAt: "2026-06-25T21:30:00.000Z",
            transcript: "Latest clip"
        )

        let groups = SettingsHistoryArchive.load(from: tempRoot)

        XCTAssertEqual(groups.map(\.dayKey), ["2026-06-25", "2026-06-23"])
        XCTAssertEqual(
            try groups[1].dayTitle(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: XCTUnwrap(TimeZone(secondsFromGMT: 0))
            ),
            "Jun 23, 2026"
        )
        XCTAssertEqual(groups[0].entries.map(\.transcript), ["Latest clip", "Morning clip"])
        XCTAssertEqual(groups[1].entries.map(\.transcript), ["Eitan was misheard in the old clip"])
        let timestamps = groups[0].entries.map {
            $0.timestamp(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(
            timestamps,
            [
                "9:30 PM",
                "7:05 AM",
            ]
        )
        XCTAssertEqual(groups[1].entries[0].audioPath.lastPathComponent, "audio.wav")
    }

    func testLoadPageBoundsMaterializedEntriesNewestFirstAndMarksOlderAvailable() throws {
        for hour in 0 ..< 5 {
            try writeRecording(
                day: "2026-06-24",
                id: "2026-06-24T0\(hour)-00-00-000Z-clip-\(hour)",
                createdAt: "2026-06-24T0\(hour):00:00.000Z",
                transcript: "Older clip \(hour)"
            )
        }
        try writeRecording(
            day: "2026-06-25",
            id: "2026-06-25T07-05-00-000Z-first",
            createdAt: "2026-06-25T07:05:00.000Z",
            transcript: "Morning clip"
        )
        try writeRecording(
            day: "2026-06-25",
            id: "2026-06-25T21-30-00-000Z-latest",
            createdAt: "2026-06-25T21:30:00.000Z",
            transcript: "Latest clip"
        )

        let page = SettingsHistoryArchive.loadPage(from: tempRoot, limit: 3)

        XCTAssertEqual(page.loadedEntryCount, 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.groups.map(\.dayKey), ["2026-06-25", "2026-06-24"])
        XCTAssertEqual(
            page.groups.flatMap(\.entries).map(\.transcript),
            ["Latest clip", "Morning clip", "Older clip 4"]
        )
    }

    func testLoadsCapturedVoiceAskWithoutTranscriptForHistoryRetranscription() throws {
        let id = "2026-08-01T13-14-02-000Z-abcd1234"
        let dir = tempRoot
            .appendingPathComponent("2026-08-01")
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        let metadata = """
        {
          "id": "\(id)",
          "created_at": "2026-08-01T13:14:02.000Z",
          "source": "voice_ask",
          "transcription_status": "captured",
          "backend": null
        }
        """
        try metadata.write(
            to: dir.appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )

        let groups = SettingsHistoryArchive.load(from: tempRoot)
        let entry = try XCTUnwrap(groups.first?.entries.first)

        XCTAssertEqual(entry.recordingID, id)
        XCTAssertFalse(entry.hasTranscript)
        XCTAssertEqual(entry.displayTranscript, "No transcript stored")
        XCTAssertEqual(entry.audioPath.lastPathComponent, "audio.wav")
        XCTAssertEqual(entry.audioPath.deletingLastPathComponent().lastPathComponent, id)
    }

    func testSkipsIncompleteAndTemporaryArchiveDirectories() throws {
        try writeRecording(
            day: "2026-06-25",
            id: "2026-06-25T07-05-00-000Z-complete",
            createdAt: "2026-06-25T07:05:00.000Z",
            transcript: "Complete clip"
        )
        try writeRecording(
            day: "2026-06-25",
            id: ".tmp-2026-06-25T07-06-00-000Z-staging",
            createdAt: "2026-06-25T07:06:00.000Z",
            transcript: "Temporary clip"
        )
        let incompleteDir = tempRoot
            .appendingPathComponent("2026-06-25")
            .appendingPathComponent("2026-06-25T07-07-00-000Z-incomplete")
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        try "no audio".write(
            to: incompleteDir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )

        let groups = SettingsHistoryArchive.load(from: tempRoot)

        XCTAssertEqual(groups.flatMap(\.entries).map(\.transcript), ["Complete clip"])
    }

    private func writeRecording(
        day: String,
        id: String,
        createdAt: String,
        transcript: String
    ) throws {
        let dir = tempRoot.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try transcript.write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        let metadata = """
        {
          "id": "\(id)",
          "created_at": "\(createdAt)",
          "transcription_status": "transcribed"
        }
        """
        try metadata.write(
            to: dir.appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
