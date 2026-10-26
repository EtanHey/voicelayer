import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

final class SettingsSpeechHistoryTests: XCTestCase {
    func testArchiveStatusesAndMissingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, status) in ["completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"].enumerated() {
            let id = "2026-10-26T12-00-0\(index)-000Z-abcdef12"
            let entry = root.appendingPathComponent("2026-10-26/\(id)")
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["schema_version": 1, "source": "speak", "id": id,
                "created_at": "2026-10-26T12:00:0\(index)Z", "status": status,
                "requested": ["voice": "Test voice"],
                "lifecycle": ["summary": ["generated_audio_ms": 3200, "error_code": "PLAYER_FAILED"]],
                "artifacts": [["role": "playback_ready", "relative_path": "audio/missing.mp3"]]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: entry.appendingPathComponent("metadata.json"))
            try "Original **selection**".write(to: entry.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
            try "Original selection".write(to: entry.appendingPathComponent("spoken.txt"), atomically: true, encoding: .utf8)
        }
        let entries = SettingsSpeechHistoryArchive.load(from: root)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(Set(entries.map(\.statusLabel)), ["Completed", "Stopped", "Cancelled", "Failed", "Interrupted"])
        for entry in entries {
            XCTAssertNil(entry.audioPath)
            XCTAssertEqual(entry.originalText, "Original **selection**")
            XCTAssertEqual(entry.spokenText, "Original selection")
            XCTAssertTrue(entry.textsDiffer)
            XCTAssertEqual(entry.voice, "Test voice")
            XCTAssertEqual(entry.durationLabel, "0:03")
            XCTAssertEqual(entry.reason, "PLAYER_FAILED")
        }
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root.appendingPathComponent("absent")), [])
    }
    func testLiveContractPreservesOriginalAndOrdersGeneratedChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-10-26T12-00-00-000Z-abcdef12"
        let entry = root.appendingPathComponent("2026-10-26/" + id)
        try FileManager.default.createDirectory(at: entry.appendingPathComponent("audio"), withIntermediateDirectories: true)
        let metadata = #"{"schema_version":1,"source":"speak","id":"\#(id)","created_at":"2026-10-26T12:00:00Z","status":"playing","speech":{"state":"cancelled","reason":"USER_CANCELLED","generated":[{"index":1,"text":"second","audio_path":"audio/second.mp3","voice":"B"},{"index":0,"text":"first","audio_path":"audio/first.mp3","voice":"A"}]}}"#
        try metadata.write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try "  Original **selection**\n".write(to: entry.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: entry.appendingPathComponent("audio/first.mp3"))
        try Data([2]).write(to: entry.appendingPathComponent("audio/second.mp3"))
        let record = try XCTUnwrap(SettingsSpeechHistoryArchive.load(from: root).first)
        XCTAssertEqual(record.statusLabel, "Cancelled")
        XCTAssertEqual(record.reason, "USER_CANCELLED")
        XCTAssertEqual(record.originalText, "  Original **selection**\n")
        XCTAssertEqual(record.spokenText, "first second")
        XCTAssertNil(record.durationMs, "Cancelled fixture has no recorded playback")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("speechTextDetail(\"Requested text\", text: entry.originalText)"))
        XCTAssertTrue(source.contains("speechTextDetail(\"Generated speech text\", text: entry.spokenText)"))
        XCTAssertFalse(source.contains("Actually spoken"))

        XCTAssertEqual(record.audioPaths.map(\.lastPathComponent), ["first.mp3", "second.mp3"])
        XCTAssertEqual(record.mediaPart.actions, [.play, .copy, .finder])
        XCTAssertEqual(record.mediaPart.actionableText, "first second")
        for state in ["completed", "stopped", "cancelled", "failed", "interrupted"] {
            let updated = metadata.replacingOccurrences(of: #""state":"cancelled""#, with: "\"state\":\"" + state + "\"")
            try updated.write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
            XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root).first?.statusLabel, state.capitalized)
        }
        let active = metadata.replacingOccurrences(of: #""state":"cancelled""#,
            with: #""state":"playing","played_ms":1000,"playing_since":"2026-10-26T12:00:00Z""#)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T12:00:02Z"))
        try active.write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root, now: now).first?.durationMs, 3000)
        try active.replacingOccurrences(of: #""state":"playing""#, with: #""state":"paused""#)
            .write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root, now: now).first?.durationMs, 1000)
        // Escaping audio references cannot enable playback or Finder.
        try FileManager.default.removeItem(at: entry.appendingPathComponent("audio/second.mp3"))
        try FileManager.default.createSymbolicLink(at: entry.appendingPathComponent("audio/second.mp3"), withDestinationURL: root.appendingPathComponent("outside.mp3"))
        try Data([3]).write(to: root.appendingPathComponent("outside.mp3"))
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root).first?.audioPaths.count, 1)
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root).first?.missingAudioCount, 1)
    }

    @MainActor
    func testSeekingToChunkEndContinuesRetainedQueue() {
        assertSeekingContinuesQueue(skip: false)
    }

    @MainActor
    func testSkippingPastChunkEndContinuesRetainedQueue() {
        assertSeekingContinuesQueue(skip: true)
    }

    @MainActor
    private func assertSeekingContinuesQueue(skip: Bool) {
        var started: [URL] = []
        var stops = 0
        let urls = ["first", "second", "third"].map { URL(fileURLWithPath: "/fixture/" + $0) }
        let player = SettingsAudioPlayback(start: { started.append($0); return true },
            stop: { stops += 1 },
            position: { .init(currentTime: 8, duration: 10) })
        player.toggle(urls)
        if skip { player.skip(urls[0], by: 5) } else { player.seek(urls[0], to: 10) }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(started, Array(urls.prefix(2)))
        XCTAssertEqual(player.playingURL, urls[1])
        XCTAssertTrue(player.isPlaying(urls[0]))
        player.playbackDidFinish(urls[0]) // A stale completion must not skip the next chunk.
        XCTAssertEqual(player.playingURL, urls[1])
        player.playbackDidFinish(urls[1])
        XCTAssertEqual(started, urls)
        player.stop()
        player.playbackDidFinish(urls[2])
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(started, urls)
    }

    @MainActor
    func testRetainedChunksPlayInOrderAndStopClearsQueue() {
        var started: [URL] = []
        let player = SettingsAudioPlayback(start: { started.append($0); return true }, stop: {})
        let urls = ["first", "second"].map { URL(fileURLWithPath: "/fixture/" + $0) }
        player.toggle(urls)
        player.playbackDidFinish(urls[0])
        XCTAssertEqual(started, urls)
        XCTAssertTrue(player.isPlaying(urls[0]))
        player.toggle(urls)
        player.playbackDidFinish(urls[1])
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(started.count, 2)
        player.toggle(urls)
        player.setVoiceOwner("fixture", busy: true)
        player.playbackDidFinish(urls[0])
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(started.count, 3, "Voice ownership cancels the remaining chunks")
    }

    @MainActor
    func testSpeechHistoryPresentationInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-10-26T12-00-00-000Z-abcdef12"
        let entry = root.appendingPathComponent("2026-10-26/" + id)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try #"{"schema_version":1,"source":"speak","id":"\#(id)","created_at":"2026-10-26T12:00:00Z","status":"interrupted_unknown","requested":{"voice":"Andrew"}}"#.write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try "A retained spoken output after restart.".write(to: entry.appendingPathComponent("spoken.txt"), atomically: true, encoding: .utf8)
        try "Original **selected** text.".write(to: entry.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs.local/FINISH-1026")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 }, historyPage: { _ in .init(groups: [], hasMore: false) }, askHistoryPage: { _ in .init(groups: [], hasMore: false) }, searchPrewarm: {}, initialTab: .history, initialHistoryScope: .speech, speechHistoryRoot: root, initialSpeechEntryID: id)
            let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = host
            let settled = expectation(description: "Speech fixtures load")
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(600)); settled.fulfill() }
            wait(for: [settled], timeout: 5)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("speech-\(name).png"))
            window.contentView = nil
        }
    }

}
