import Foundation
@testable import VoiceBarUI
import XCTest

final class SettingsHistoryIncrementalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor
    func testPagePagingAndEventDiskReadsLeaveTheMainThread() async throws {
        let entry = try write("b", text: "newest")
        _ = try write("a", text: "older")
        let probe = DiskReadProbe()
        let index = SettingsArchiveIndex(onDiskRead: { probe.record() })
        let first = await index.dictationPage(from: root, limit: 1)
        let older = await index.dictationPage(from: root, limit: 2)
        let change = await index.change(entryPath: entry.path, from: root)
        XCTAssertEqual(first.loadedEntryCount, 1)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(older.loadedEntryCount, 2)
        XCTAssertNotNil(change)
        XCTAssertEqual(probe.observations, [false, false, false], "all three production disk-read entry points run off main")
    }

    func testAnEventChangesOneRowAndKeepsEveryOtherRowAndSelectionIdentity() async throws {
        let changedURL = try write("b", text: "old words")
        let untouchedURL = try write("a", text: "untouched")
        let index = SettingsArchiveIndex()
        let before = await index.dictationPage(from: root, limit: 100)
        let selectedID = try XCTUnwrap(before.groups.first?.entries.last?.id)
        try "new words".write(to: changedURL.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        // A whole-page rescan would see this unrelated write. A row event must not read it.
        try "not part of this event".write(to: untouchedURL.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        let loaded = await index.change(entryPath: changedURL.path, from: root)
        let change = try XCTUnwrap(loaded)
        let after = change.applying(to: before)
        let oldRows = before.groups.flatMap(\.entries)
        let newRows = after.groups.flatMap(\.entries)
        XCTAssertEqual(newRows.map(\.transcript), ["new words", "untouched"])
        XCTAssertEqual(zip(oldRows, newRows).filter { $0 != $1 }.count, 1)
        XCTAssertEqual(newRows.map(\.id), oldRows.map(\.id))
        XCTAssertTrue(newRows.contains { $0.id == selectedID })
        XCTAssertEqual(after.loadedEntryCount, before.loadedEntryCount)
        XCTAssertEqual(change.applying(to: after), after, "replaying an event after paging is idempotent")
        let indexed = await index.dictationPage(from: root, limit: 100)
        XCTAssertEqual(indexed, after, "the page cache now contains the fresh row without rereading the neighbor")
    }

    func testNewRowExtendsLoadedWindowWithoutDroppingSelectedTail() async throws {
        _ = try write("b", text: "selected")
        _ = try write("a", text: "not loaded yet")
        let index = SettingsArchiveIndex()
        let before = await index.dictationPage(from: root, limit: 1)
        let newURL = try write("c", text: "new dictation")
        let loaded = await index.change(entryPath: newURL.path, from: root)
        let change = try XCTUnwrap(loaded)
        let after = change.applying(to: before)
        XCTAssertEqual(after.groups.flatMap(\.entries).map(\.transcript), ["new dictation", "selected"])
        XCTAssertTrue(after.hasMore)
        XCTAssertEqual(after.loadedEntryCount, 2)
        let oldURL = root.appendingPathComponent("2026-11-02/a/audio.wav")
        let oldLoaded = await index.change(entryPath: oldURL.path, from: root)
        XCTAssertEqual(try XCTUnwrap(oldLoaded).applying(to: after), after, "an old unloaded row does not enter the page")
    }

    func testSearchMembershipChangesWithoutRescanningAndAskStaysSeparate() async throws {
        let path = try write("b", text: "match before")
        let askPath = try write("q", text: "answer before", ask: true)
        let index = SettingsArchiveIndex()
        let dictations = await index.dictationPage(from: root, limit: 100, matching: "match")
        let asks = await index.askPage(from: root, limit: 100)
        try "no longer relevant".write(to: path.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        let loaded = await index.change(entryPath: path.path, from: root)
        let change = try XCTUnwrap(loaded)
        XCTAssertEqual(change.applying(to: dictations, matching: "match").loadedEntryCount, 0)
        XCTAssertEqual(change.applying(to: asks), asks)
        try "answer after".write(to: askPath.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        let askLoaded = await index.change(entryPath: askPath.path, from: root)
        let askChange = try XCTUnwrap(askLoaded)
        XCTAssertEqual(askChange.applying(to: asks).groups.first?.entries.first?.responseTranscript, "answer after")
        XCTAssertEqual(askChange.applying(to: dictations), dictations)
        let outside = await index.change(entryPath: root.appendingPathComponent("outside.wav").path, from: root)
        XCTAssertNil(outside)
    }

    @MainActor
    func testKnownPathEventsKeepPagingAndReplayAfterBothScopeSnapshots() async throws {
        let path = try write("a", text: "before")
        let askPath = try write("q", text: "answer before", ask: true)
        let index = SettingsArchiveIndex()
        let snapshot = await index.dictationPage(from: root)
        let askSnapshot = await index.askPage(from: root)
        try "after".write(to: path.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        try "answer after".write(to: askPath.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        let loaded = await index.change(entryPath: path.path, from: root)
        let askLoaded = await index.change(entryPath: askPath.path, from: root)
        let change = try XCTUnwrap(loaded)
        let askChange = try XCTUnwrap(askLoaded)
        var displayed = snapshot
        var displayedAsk = askSnapshot
        var events: [String] = []
        var changes = SettingsHistoryArchiveChanges()
        var askChanges = SettingsHistoryArchiveChanges()
        let inFlight = Task { (snapshot, askSnapshot, Task.isCancelled) }
        let apply: (SettingsHistoryArchiveChange) -> Void = {
            events.append("dictation-row")
            displayed = $0.applying(to: displayed)
        }
        let applyAsk: (SettingsHistoryArchiveChange) -> Void = {
            events.append("ask-row")
            displayedAsk = $0.applying(to: displayedAsk)
        }
        changes.receive(change, duringLoad: true, apply: apply)
        askChanges.receive(askChange, duringLoad: true, apply: applyAsk)
        XCTAssertEqual(displayed.groups.first?.entries.first?.transcript, "after")
        XCTAssertEqual(displayedAsk.groups.first?.entries.first?.responseTranscript, "answer after")
        let (page, askPage, cancelled) = await inFlight.value
        XCTAssertFalse(cancelled, "receiving a row event leaves the existing paging task running")
        changes.publish(page, applyPage: { events.append("dictation-page"); displayed = $0 }, applyChange: apply)
        askChanges.publish(askPage, applyPage: { events.append("ask-page"); displayedAsk = $0 }, applyChange: applyAsk)
        XCTAssertEqual(events, ["dictation-row", "ask-row", "dictation-page", "dictation-row", "ask-page", "ask-row"])
        XCTAssertEqual(displayed.groups.first?.entries.first?.transcript, "after")
        XCTAssertEqual(displayedAsk.groups.first?.entries.first?.responseTranscript, "answer after")
        XCTAssertTrue(changes.takePending().isEmpty)
        XCTAssertTrue(askChanges.takePending().isEmpty)
    }

    func testClosedSettingsEventsPerformNoDiskReadsBeforeOrAfterRelease() async throws {
        let path = try write("a", text: "words")
        let probe = DiskReadProbe()
        let index = SettingsArchiveIndex(onDiskRead: { probe.record() })
        let unopened = await index.change(entryPath: path.path, from: root)
        XCTAssertNil(unopened)
        XCTAssertTrue(probe.observations.isEmpty)
        _ = await index.dictationPage(from: root)
        let reads = probe.observations.count
        await index.release()
        for _ in 0 ..< 3 {
            let closed = await index.change(entryPath: path.path, from: root)
            XCTAssertNil(closed)
        }
        XCTAssertEqual(probe.observations.count, reads, "no path resolution, metadata or transcript reads with Settings closed")
        let roots = await index.cachedRootCount()
        XCTAssertEqual(roots, 0)
    }

    func testOutOfOrderEventsCannotOverwriteTheLatestRowOrPendingReplay() async throws {
        let path = try write("a", text: "before")
        let index = SettingsArchiveIndex()
        let snapshot = await index.dictationPage(from: root, limit: 100)
        let firstLoaded = await index.change(entryPath: path.path, from: root)
        let first = try XCTUnwrap(firstLoaded)
        try "latest".write(to: path.deletingLastPathComponent().appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        let latestLoaded = await index.change(entryPath: path.path, from: root)
        let latest = try XCTUnwrap(latestLoaded)
        var changes = SettingsHistoryArchiveChanges()
        XCTAssertTrue(changes.receive(latest, duringLoad: true))
        XCTAssertFalse(changes.receive(first, duringLoad: true))
        let pending = changes.takePending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.revision, latest.revision)
        XCTAssertEqual(pending.reduce(snapshot) { $1.applying(to: $0) }.groups.first?.entries.first?.transcript, "latest")
        XCTAssertTrue(changes.takePending().isEmpty)
        XCTAssertFalse(changes.receive(first, duringLoad: false))
    }

    private func write(_ id: String, text: String, ask: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent("2026-11-02/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio.wav")
        try Data([0]).write(to: audio)
        try text.write(to: directory.appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8)
        if ask { try "question".write(to: directory.appendingPathComponent("agent-transcript.txt"), atomically: true, encoding: .utf8) }
        let metadata = "{\"id\":\"\(id)\",\"created_at\":\"2026-11-02T00:00:00Z\",\"source\":\"\(ask ? SettingsArchiveSchema.askSourceValue : "voicebar")\"}"
        try metadata.write(to: directory.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        return audio
    }
}

private final class DiskReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    var observations: [Bool] { lock.withLock { values } }
    func record() { lock.withLock { values.append(Thread.isMainThread) } }
}
