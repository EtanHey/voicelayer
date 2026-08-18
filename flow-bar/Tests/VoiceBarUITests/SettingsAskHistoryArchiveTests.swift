@testable import VoiceBarUI
import XCTest

final class SettingsAskHistoryArchiveTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicelayer-settings-ask-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testAskEntryCarriesBothSidesOfTheExchange() throws {
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T13-14-02-000Z-abcd1234",
            createdAt: "2026-08-01T13:14:02.000Z",
            question: "Should I ship the notch redesign tonight?",
            response: "Not tonight, the teleprompter sync is still off"
        )

        let groups = SettingsAskHistoryArchive.load(from: tempRoot)
        let entry = try XCTUnwrap(groups.first?.entries.first)

        XCTAssertEqual(entry.askID, "2026-08-01T13-14-02-000Z-abcd1234")
        XCTAssertEqual(entry.questionText, "Should I ship the notch redesign tonight?")
        XCTAssertEqual(entry.responseTranscript, "Not tonight, the teleprompter sync is still off")
        XCTAssertTrue(entry.hasResponseTranscript)
        XCTAssertEqual(entry.questionAudioPath?.lastPathComponent, "agent-audio.mp3")
        XCTAssertEqual(entry.responseAudioPath?.lastPathComponent, "audio.wav")
    }

    func testAskEntryExistsWhenTranscriptionNeverCameBack() throws {
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T13-14-02-000Z-failed",
            createdAt: "2026-08-01T13:14:02.000Z",
            question: "Did that land?",
            response: nil
        )

        let groups = SettingsAskHistoryArchive.load(from: tempRoot)
        let entry = try XCTUnwrap(groups.first?.entries.first)

        XCTAssertEqual(entry.questionText, "Did that land?")
        XCTAssertFalse(entry.hasResponseTranscript)
        XCTAssertEqual(entry.displayResponseTranscript, "No transcript stored")
        XCTAssertEqual(entry.responseAudioPath?.lastPathComponent, "audio.wav")
    }

    func testAskListExcludesVoiceBarRecordings() throws {
        try writeVoiceBarRecording(
            day: "2026-08-01",
            id: "2026-08-01T09-00-00-000Z-f5clip",
            createdAt: "2026-08-01T09:00:00.000Z",
            transcript: "An F5 dictation that must stay out of Ask"
        )
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T13-14-02-000Z-ask",
            createdAt: "2026-08-01T13:14:02.000Z",
            question: "Only this one belongs here",
            response: "Yes"
        )

        let entries = SettingsAskHistoryArchive.load(from: tempRoot).flatMap(\.entries)

        XCTAssertEqual(entries.map(\.questionText), ["Only this one belongs here"])
    }

    func testAskPageBoundsEntriesNewestFirstAndMarksOlderAvailable() throws {
        for hour in 0 ..< 4 {
            try writeAsk(
                day: "2026-08-01",
                id: "2026-08-01T0\(hour)-00-00-000Z-ask-\(hour)",
                createdAt: "2026-08-01T0\(hour):00:00.000Z",
                question: "Question \(hour)",
                response: "Answer \(hour)"
            )
        }

        let page = SettingsAskHistoryArchive.loadPage(from: tempRoot, limit: 2)

        XCTAssertEqual(page.loadedEntryCount, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.groups.flatMap(\.entries).map(\.questionText), ["Question 3", "Question 2"])
    }

    func testAskPageReportsNoMoreWhenEverythingLoaded() throws {
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T01-00-00-000Z-only",
            createdAt: "2026-08-01T01:00:00.000Z",
            question: "Only question",
            response: "Only answer"
        )

        let page = SettingsAskHistoryArchive.loadPage(from: tempRoot, limit: 100)

        XCTAssertEqual(page.loadedEntryCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testSkipsStagingDirectories() throws {
        try writeAsk(
            day: "2026-08-01",
            id: ".tmp-2026-08-01T13-00-00-000Z-staging",
            createdAt: "2026-08-01T13:00:00.000Z",
            question: "Staged",
            response: "Staged"
        )
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T14-00-00-000Z-complete",
            createdAt: "2026-08-01T14:00:00.000Z",
            question: "Complete",
            response: "Complete"
        )

        let entries = SettingsAskHistoryArchive.load(from: tempRoot).flatMap(\.entries)

        XCTAssertEqual(entries.map(\.questionText), ["Complete"])
    }

    func testGroupsAskEntriesByDayNewestFirst() throws {
        try writeAsk(
            day: "2026-07-30",
            id: "2026-07-30T10-00-00-000Z-older",
            createdAt: "2026-07-30T10:00:00.000Z",
            question: "Older day",
            response: "Older"
        )
        try writeAsk(
            day: "2026-08-01",
            id: "2026-08-01T10-00-00-000Z-newer",
            createdAt: "2026-08-01T10:00:00.000Z",
            question: "Newer day",
            response: "Newer"
        )

        let groups = SettingsAskHistoryArchive.load(from: tempRoot)

        XCTAssertEqual(groups.map(\.dayKey), ["2026-08-01", "2026-07-30"])
        XCTAssertEqual(
            try groups[1].dayTitle(
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: XCTUnwrap(TimeZone(secondsFromGMT: 0))
            ),
            "Jul 30, 2026"
        )
    }

    // MARK: - Fixtures

    private func writeAsk(
        day: String,
        id: String,
        createdAt: String,
        question: String,
        response: String?
    ) throws {
        let dir = tempRoot.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("agent-audio.mp3"))
        try Data([4, 5, 6, 7]).write(to: dir.appendingPathComponent("audio.wav"))
        try question.write(
            to: dir.appendingPathComponent("agent-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        if let response {
            try response.write(
                to: dir.appendingPathComponent("voicelayer-transcript.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let metadata = """
        {
          "id": "\(id)",
          "created_at": "\(createdAt)",
          "source": "voice_ask",
          "transcription_status": "\(response == nil ? "captured" : "transcribed")",
          "schema_version": 3
        }
        """
        try metadata.write(
            to: dir.appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeVoiceBarRecording(
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
          "source": "voicebar",
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
