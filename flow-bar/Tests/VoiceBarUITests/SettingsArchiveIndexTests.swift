@testable import VoiceBarUI
import XCTest

/// R4/H1-a: one index for History's two scopes. A tab switch or a reopen serves decoded entries from memory
/// instead of re-walking and re-decoding the archive, and an indexed page is identical to a scanned one.
final class SettingsArchiveIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Parity with the scanner

    func testIndexedPagesAreIdenticalToScannedPagesOnAMixedArchive() async throws {
        try writeMixedArchive()
        let index = SettingsArchiveIndex()
        for limit in [0, 1, 2, 3, 5, 100] {
            let dictations = await index.dictationPage(from: root, limit: limit)
            XCTAssertEqual(
                dictations,
                SettingsHistoryArchive.loadPage(from: root, limit: limit),
                "dictations, limit \(limit)"
            )
            let asks = await index.askPage(from: root, limit: limit)
            XCTAssertEqual(asks, SettingsAskHistoryArchive.loadPage(from: root, limit: limit), "asks, limit \(limit)")
        }
    }

    // MARK: - Freshness

    func testANewRecordingAppearsOnTheNextPage() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z", transcript: "first")
        let index = SettingsArchiveIndex()
        _ = await index.dictationPage(from: root, limit: 10)
        try writeDictation(day: "2026-09-20", id: "b", createdAt: "2026-09-20T09:00:00.000Z", transcript: "second")

        let page = await index.dictationPage(from: root, limit: 10)
        XCTAssertEqual(page.groups.flatMap(\.entries).map(\.transcript), ["second", "first"])
        XCTAssertEqual(page, SettingsHistoryArchive.loadPage(from: root, limit: 10))
    }

    func testARetranscribedEntryIsFreshAfterInvalidation() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z", transcript: "old words")
        let index = SettingsArchiveIndex()
        _ = await index.dictationPage(from: root, limit: 10)
        let entryURL = root.appendingPathComponent("2026-09-20/a")
        try "new words".write(
            to: entryURL.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        await index.invalidate(entryPath: entryURL.appendingPathComponent("audio.wav").path)

        let page = await index.dictationPage(from: root, limit: 10)
        XCTAssertEqual(page.groups.flatMap(\.entries).map(\.transcript), ["new words"])
    }

    // MARK: - Release (Settings closed) and memory

    func testReleaseDropsTheCacheAndTheNextPageIsStillCorrectWithoutDuplicates() async throws {
        for hour in 0 ..< 6 {
            try writeDictation(day: "2026-09-20", id: "e\(hour)", createdAt: "2026-09-20T0\(hour):00:00.000Z",
                               transcript: "entry \(hour)")
        }
        let index = SettingsArchiveIndex()
        _ = await index.dictationPage(from: root, limit: 5)
        let cachedBeforeRelease = await index.cachedRootCount()
        XCTAssertEqual(cachedBeforeRelease, 1)
        await index.release()
        let cachedAfterRelease = await index.cachedRootCount()
        XCTAssertEqual(cachedAfterRelease, 0)
        try writeDictation(day: "2026-09-20", id: "e9", createdAt: "2026-09-20T09:00:00.000Z", transcript: "entry 9")

        let page = await index.dictationPage(from: root, limit: 6)
        let ids = page.groups.flatMap(\.entries).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no row twice after release + a new write")
        XCTAssertEqual(page, SettingsHistoryArchive.loadPage(from: root, limit: 6))
    }

    // MARK: - Fixtures

    /// #152 CodeRabbit 4100045560: a load cancelled by a scope switch must stop walking, because the actor is
    /// held until the walk ends and the next scope's page waits behind it. A partial walk must not poison the
    /// next full one.
    func testACancelledWalkStopsAndTheNextPageIsComplete() async throws {
        for index in 0 ..< 30 {
            try writeDictation(day: "2026-09-\(10 + index % 5)", id: "c\(index)",
                               createdAt: "2026-09-\(10 + index % 5)T0\(index % 10):00:00.000Z",
                               transcript: "entry \(index)")
        }
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await index.dictationPage(from: root, limit: 100)
        }.value
        XCTAssertEqual(cancelled.loadedEntryCount, 0, "a cancelled load walks nothing")

        let full = await index.dictationPage(from: root, limit: 100)
        XCTAssertEqual(full.loadedEntryCount, 30)
        XCTAssertFalse(full.hasMore)
    }

    // MARK: - H1-c search (Etan: "add search, separately for Recording and Ask")

    func testSearchReturnsOnlyMatchingDictationsNewestFirst() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z",
                           transcript: "Deploy the notch build")
        try writeDictation(day: "2026-09-20", id: "b", createdAt: "2026-09-20T09:00:00.000Z",
                           transcript: "lunch plans")
        try writeDictation(day: "2026-09-21", id: "c", createdAt: "2026-09-21T07:00:00.000Z",
                           transcript: "The NOTCH glass looks off")
        try writeAsk(day: "2026-09-21", id: "q", createdAt: "2026-09-21T08:00:00.000Z",
                     question: "Should the notch move?")
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let page = await index.dictationPage(from: root, limit: 10, matching: "notch")

        XCTAssertEqual(page.groups.flatMap(\.entries).map(\.recordingID), ["c", "a"])
        XCTAssertEqual(page.loadedEntryCount, 2)
        XCTAssertFalse(page.hasMore)
    }

    func testSearchIgnoresCaseAndDiacriticsAndFindsHebrew() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z",
                           transcript: "Meet at the Café")
        try writeDictation(day: "2026-09-20", id: "b", createdAt: "2026-09-20T09:00:00.000Z",
                           transcript: "שלום לכולם")
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let cafe = await index.dictationPage(from: root, limit: 10, matching: "CAFE")
        let hebrew = await index.dictationPage(from: root, limit: 10, matching: "שלום")

        XCTAssertEqual(cafe.groups.flatMap(\.entries).map(\.recordingID), ["a"])
        XCTAssertEqual(hebrew.groups.flatMap(\.entries).map(\.recordingID), ["b"])
    }

    /// The #148 lesson: whitespace alone is not a search.
    func testAWhitespaceQueryIsNoSearch() async throws {
        try writeMixedArchive()
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let all = await index.dictationPage(from: root, limit: 100)
        let blank = await index.dictationPage(from: root, limit: 100, matching: "  \n ")

        XCTAssertEqual(blank, all)
    }

    func testSearchPagesWithAnExactHasMore() async throws {
        for index in 0 ..< 30 {
            try writeDictation(day: "2026-09-\(10 + index % 5)", id: "m\(index)",
                               createdAt: "2026-09-\(10 + index % 5)T0\(index % 10):00:00.000Z",
                               transcript: index % 3 == 0 ? "release notes \(index)" : "other \(index)")
        }
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let first = await index.dictationPage(from: root, limit: 4, matching: "release")
        let all = await index.dictationPage(from: root, limit: 100, matching: "release")

        XCTAssertEqual(first.loadedEntryCount, 4)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(all.loadedEntryCount, 10)
        XCTAssertFalse(all.hasMore)
    }

    func testAskSearchMatchesTheQuestionOrTheResponse() async throws {
        try writeAsk(day: "2026-09-20", id: "q1", createdAt: "2026-09-20T08:00:00.000Z",
                     question: "Raise the silence timeout?", response: "Yes, to five seconds")
        try writeAsk(day: "2026-09-20", id: "q2", createdAt: "2026-09-20T09:00:00.000Z",
                     question: "Ship tonight?", response: "Only after the timeout fix")
        try writeAsk(day: "2026-09-20", id: "q3", createdAt: "2026-09-20T10:00:00.000Z",
                     question: "Lunch?", response: "Later")
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)

        let page = await index.askPage(from: root, limit: 10, matching: "timeout")

        XCTAssertEqual(page.groups.flatMap(\.entries).map(\.askID), ["q2", "q1"])
    }

    /// Search keeps each entry's text; a re-transcription must not leave the old words searchable.
    func testSearchSeesARetranscriptionAfterInvalidation() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z", transcript: "alpha")
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)
        let before = await index.dictationPage(from: root, limit: 10, matching: "alpha")
        XCTAssertEqual(before.loadedEntryCount, 1)

        let entryDir = root.appendingPathComponent("2026-09-20/a")
        try "beta".write(
            to: entryDir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        await index.invalidate(entryPath: entryDir.appendingPathComponent("audio.wav").path)

        let stale = await index.dictationPage(from: root, limit: 10, matching: "alpha")
        let fresh = await index.dictationPage(from: root, limit: 10, matching: "beta")
        XCTAssertEqual(stale.loadedEntryCount, 0)
        XCTAssertEqual(fresh.groups.flatMap(\.entries).map(\.transcript), ["beta"])
    }

    func testASearchDoesNotChangeTheUnfilteredPage() async throws {
        try writeMixedArchive()
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)
        let before = await index.dictationPage(from: root, limit: 100)

        _ = await index.dictationPage(from: root, limit: 100, matching: "zzz-no-match")
        let after = await index.dictationPage(from: root, limit: 100)

        XCTAssertEqual(after, before)
    }

    private func writeMixedArchive() throws {
        try writeDictation(
            day: "2026-09-22",
            id: "d1",
            createdAt: "2026-09-22T10:00:00.000Z",
            transcript: "newest dictation"
        )
        try writeAsk(day: "2026-09-22", id: "q1", createdAt: "2026-09-22T09:00:00.000Z", question: "newest ask?")
        try writeDictation(
            day: "2026-09-22",
            id: "d0",
            createdAt: "2026-09-22T08:00:00.000Z",
            transcript: "older dictation"
        )
        // No audio: skipped by the dictation list.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026-09-22/no-audio"),
                                                withIntermediateDirectories: true)
        // A staging directory and a non-day directory: skipped by both.
        try writeDictation(
            day: "2026-09-22",
            id: ".tmp-staging",
            createdAt: "2026-09-22T11:00:00.000Z",
            transcript: "staging"
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try writeAsk(day: "2026-09-21", id: "q0", createdAt: "2026-09-21T09:00:00.000Z", question: "older ask?")
        try writeDictation(day: "2026-09-21", id: "d-1", createdAt: "2026-09-21T07:00:00.000Z", transcript: "yesterday")
        try writeDictation(day: "2026-09-19", id: "d-2", createdAt: "2026-09-19T07:00:00.000Z", transcript: "earlier")
    }

    private func writeDictation(day: String, id: String, createdAt: String, transcript: String) throws {
        let dir = root.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try transcript.write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id": "\#(id)", "created_at": "\#(createdAt)", "duration_ms": 1200}"#
            .write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    private func writeAsk(
        day: String,
        id: String,
        createdAt: String,
        question: String,
        response: String = "an answer"
    ) throws {
        let dir = root.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try question.write(to: dir.appendingPathComponent("agent-transcript.txt"), atomically: true, encoding: .utf8)
        try response.write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id": "\#(id)", "created_at": "\#(createdAt)", "source": "\#(SettingsArchiveSchema.askSourceValue)"}"#
            .write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }
}
