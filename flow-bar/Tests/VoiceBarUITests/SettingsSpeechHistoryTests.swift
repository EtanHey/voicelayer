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

    func testArchiveLoadStopsScanningWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            let id = "2026-10-26T12-00-0\(index)-000Z-abcdef12"
            let entry = root.appendingPathComponent("2026-10-26/\(id)")
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["schema_version": 1, "source": "speak", "id": id,
                "created_at": "2026-10-26T12:00:0\(index)Z", "status": "completed"]
            try JSONSerialization.data(withJSONObject: metadata).write(to: entry.appendingPathComponent("metadata.json"))
        }
        XCTAssertEqual(SettingsSpeechHistoryArchive.load(from: root).count, 3)
        let cancelled = Task.detached { () -> [SettingsSpeechHistoryEntry] in
            withUnsafeCurrentTask { $0?.cancel() }
            return SettingsSpeechHistoryArchive.load(from: root)
        }
        let entries = await cancelled.value
        XCTAssertEqual(entries, [], "A cancelled scan must stop before reading entries")
    }

    // `.task(id:)` cancels the previous task when the id changes; the scan it started must stop too.
    func testRestartedLoadCancelsPreviousScan() async {
        let probe = ReloadProbe()
        let first = Task {
            await SettingsSpeechHistoryReload.run(debounce: false) {
                probe.record(.started)
                let deadline = Date().addingTimeInterval(3)
                while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                probe.record(Task.isCancelled ? .cancelled : .ranToDeadline)
                return []
            }
        }
        let startDeadline = Date().addingTimeInterval(2)
        while !probe.events.contains(.started), Date() < startDeadline { await Task.yield() }
        XCTAssertEqual(probe.events, [.started], "The first scan never started")
        first.cancel()
        let second = await SettingsSpeechHistoryReload.run(debounce: false) { [] }
        let stale = await first.value
        XCTAssertNil(stale, "A restarted load must not deliver the stale scan")
        XCTAssertEqual(second, [])
        XCTAssertEqual(probe.events, [.started, .cancelled], "The previous scan must observe cancellation")
    }

    // `run` checks cancellation off the main actor; a cancel can land after it returns entries but
    // before the main-actor continuation applies them. Holding the main actor opens exactly that window.
    @MainActor
    func testCancelAfterLoadReturnsSkipsApply() async {
        let probe = ReloadProbe()
        var applied: [[SettingsSpeechHistoryEntry]] = []
        let reload = Task {
            await SettingsSpeechHistoryReload.reload(debounce: false, load: {
                probe.record(.started)
                while !probe.isReleased { Thread.sleep(forTimeInterval: 0.001) }
                probe.record(.returned)
                return []
            }, apply: { applied.append($0) })
        }
        let startDeadline = Date().addingTimeInterval(2)
        while !probe.events.contains(.started), Date() < startDeadline { await Task.yield() }
        guard probe.events.contains(.started) else {
            reload.cancel()
            return XCTFail("The load never started")
        }
        // No awaits from here until the cancel: the main actor stays busy, so the apply cannot run.
        probe.release()
        while !probe.events.contains(.returned) { Thread.sleep(forTimeInterval: 0.001) }
        Thread.sleep(forTimeInterval: 0.2) // let `run` finish its own check and return the entries
        reload.cancel()
        await reload.value
        XCTAssertTrue(applied.isEmpty, "A load cancelled before its main-actor apply must not apply")
    }

    // Refresh and Load older are user actions: a notification that just arrived must not make them wait.
    func testButtonsLoadImmediatelyAfterArchiveChange() {
        var request = SettingsSpeechHistoryReloadRequest()
        let initial = request.taskID
        request.archiveChanged()
        XCTAssertNotEqual(request.taskID, initial)
        request.refresh()
        XCTAssertFalse(request.takeDebounce(), "Refresh after a notification must load immediately")

        request.archiveChanged()
        let beforeOlder = request.taskID
        request.loadOlder()
        XCTAssertEqual(request.limit, 200)
        XCTAssertNotEqual(request.taskID, beforeOlder)
        XCTAssertFalse(request.takeDebounce(), "Load older after a notification must load immediately")

        request.archiveChanged()
        XCTAssertTrue(request.takeDebounce())
        XCTAssertFalse(request.takeDebounce(), "The debounce applies to one load only")
    }

    // Mirrors the Dictations/Ask reloads: each archive-change notification restarts the load, and only
    // the one that survives the 300 ms wait scans.
    func testNotificationBurstProducesOneLoad() async {
        let probe = ReloadProbe()
        var current: Task<[SettingsSpeechHistoryEntry]?, Never>?
        for _ in 0..<5 {
            current?.cancel()
            current = Task {
                await SettingsSpeechHistoryReload.run(debounce: true) {
                    probe.record(.started)
                    return []
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let entries = await current?.value
        XCTAssertEqual(entries, [])
        XCTAssertEqual(probe.events, [.started], "A burst of notifications must scan once")
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

private final class ReloadProbe: @unchecked Sendable {
    enum Event: Equatable { case started, cancelled, ranToDeadline, returned }
    private let lock = NSLock()
    private var recorded: [Event] = []
    private var released = false
    var events: [Event] { lock.withLock { recorded } }
    var isReleased: Bool { lock.withLock { released } }
    func record(_ event: Event) { lock.withLock { recorded.append(event) } }
    func release() { lock.withLock { released = true } }
}
