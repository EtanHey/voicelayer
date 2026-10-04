@testable import VoiceBarUI
import XCTest

/// F1 review round 1 (RX2, Medium): the spoken length is written after the transcript is delivered, so a History
/// page loaded in between cached the entry without it, and the index kept serving that copy. The daemon now
/// announces the durable write (`archive_metadata_updated`) and VoiceBar routes it to the same entry
/// invalidation + reload a transcription triggers, without re-running anything a transcription does.
@MainActor
final class SettingsHistoryDeferredTimingTests: XCTestCase {
    func testCutOffAskResponseReloadsInItsOriginalExchangeAfterMCPArchiveUpdate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-09-27T10-00-00-000Z-abcd1234"
        let dir = root.appendingPathComponent("2026-09-27/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("audio.wav")
        try Data([0, 1]).write(to: audio)
        try "Synthetic question?".write(
            to: dir.appendingPathComponent("agent-transcript.txt"), atomically: true, encoding: .utf8
        )
        let metadata = dir.appendingPathComponent("metadata.json")
        try #"{"id":"\#(id)","source":"voice_ask","transcription_status":"captured","duration_ms":88000}"#
            .write(to: metadata, atomically: true, encoding: .utf8)
        let index = SettingsArchiveIndex()
        let before = await index.askPage(from: root)
        let original = try XCTUnwrap(before.groups.first?.entries.first)
        XCTAssertFalse(original.hasResponseTranscript)
        await index.prewarmSearchText(from: root)

        let answer = "Recovered synthetic answer, fu… keep keep the retraction."
        try answer.write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8
        )
        try #"{"id":"\#(id)","source":"voice_ask","transcription_status":"transcribed","duration_ms":88000}"#
            .write(to: metadata, atomically: true, encoding: .utf8)
        let cached = await index.askPage(from: root)
        XCTAssertFalse(try XCTUnwrap(cached.groups.first?.entries.first).hasResponseTranscript)

        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        var invalidated: [String] = []
        var commands: [[String: Any]] = []
        state.onHistoryArchiveChange = { path in if let path { invalidated.append(path) } }
        state.sendCommand = { commands.append($0) }
        state.handleEvent(["type": "archive_metadata_updated", "recording_path": audio.path])
        XCTAssertEqual(invalidated, [audio.path])
        for path in invalidated {
            await index.invalidate(entryPath: path)
        }

        let after = await index.askPage(from: root)
        let entry = try XCTUnwrap(after.groups.first?.entries.first)
        XCTAssertEqual(after.loadedEntryCount, 1)
        XCTAssertEqual(entry.id, original.id)
        XCTAssertEqual(entry.askID, id)
        XCTAssertEqual(entry.questionText, original.questionText)
        XCTAssertEqual(entry.responseAudioPath, original.responseAudioPath)
        XCTAssertEqual(entry.responseTranscript, answer)
        let search = await index.askPage(from: root, matching: "Recovered")
        XCTAssertEqual(search.groups.first?.entries.first?.responseTranscript, answer)
        XCTAssertTrue(state.recentTranscriptions.isEmpty)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(state.mode, .idle)
    }

    func testAnEntryLoadedBeforeTheDeferredWriteShowsSpokenLengthAfterTheCompletionEvent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deferred-timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026-09-27/2026-09-27T10-00-00-000Z-timing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("audio.wav")
        try Data([0, 1]).write(to: audio)
        try "Synthetic fixture text".write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"), atomically: true, encoding: .utf8
        )
        let metadata = dir.appendingPathComponent("metadata.json")
        let finalized = #"{"source":"voicebar","duration_ms":9000,"transcribed_duration_ms":9000,"processing_duration_ms":1234"#
        try (finalized + "}").write(to: metadata, atomically: true, encoding: .utf8)

        let index = SettingsArchiveIndex()
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var invalidated: [String] = []
        state.onHistoryArchiveChange = { path in if let path { invalidated.append(path) } }
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }

        // Transcript delivered; History loads the entry before the deferred measurement lands.
        await index.invalidate(entryPath: audio.path)
        let atDelivery = await index.dictationPage(from: root)
        XCTAssertNil(atDelivery.groups.first?.entries.first?.spokenDurationMs)

        // The deferred write lands, then the daemon announces it.
        try (finalized + #","spoken_duration_ms":4000}"#).write(to: metadata, atomically: true, encoding: .utf8)
        state.handleEvent(["type": "archive_metadata_updated", "recording_path": audio.path])
        XCTAssertEqual(invalidated, [audio.path], "routed to the History entry invalidation + reload")
        for path in invalidated {
            await index.invalidate(entryPath: path)
        }

        let afterCompletion = await index.dictationPage(from: root)
        XCTAssertEqual(afterCompletion.groups.first?.entries.first?.spokenDurationMs, 4000)
        XCTAssertEqual(afterCompletion.groups.first?.entries.first?.processingDurationMs, 1234)

        // Not a transcription: nothing pasted, remembered or sent.
        XCTAssertTrue(state.recentTranscriptions.isEmpty)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(state.mode, .idle)
    }

    func testACompletionEventWithoutAPathIsIgnored() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var calls = 0
        state.onHistoryArchiveChange = { _ in calls += 1 }

        state.handleEvent(["type": "archive_metadata_updated"])
        state.handleEvent(["type": "archive_metadata_updated", "recording_path": "  "])

        XCTAssertEqual(calls, 0)
    }
}
