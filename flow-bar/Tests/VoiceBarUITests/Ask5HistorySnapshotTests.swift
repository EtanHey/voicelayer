import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

/// Explicit opt-in, synthetic-only, offscreen view rendering. No app/runtime launch or audio actions.
@MainActor
final class Ask5HistorySnapshotTests: XCTestCase {
    func testSyntheticHistorySnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["ASK5_SNAPSHOT_OUTPUT"] else { throw XCTSkip("ASK5_SNAPSHOT_OUTPUT required") }
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, width, height) in [("narrow",780.0,660.0),("default",960,760),("wide",1280,800),("long",960,760),("expanded",960,840),("empty",960,760),("failed",960,760)] {
            let text = name == "long" || name == "expanded" ? Array(repeating: "Synthetic paragraph. Keep every word, the retraction and the fragment fu… intact. This sample tests wrapping and independent scrolling.", count: 45).joined(separator: "\n\n") : "Synthetic transcript for checking the history layout. Nothing here came from a recording."
            var entries: [SettingsHistoryEntry] = []
            if name != "empty" {
                for i in 0..<12 {
                    let failed = name == "failed" && i == 0
                    let transcript = failed ? "" : (i == 0 ? text : "Synthetic saved transcript \(i)")
                    let missing: SettingsHistoryMissingTranscript? = failed ? .init(reason: "transcription-failed", detail: "Synthetic recognition failure; no engine was started.", inputDbfs: nil) : nil
                    let date = Date(timeIntervalSince1970: 1793512800 - Double(i * 120))
                    let entry = SettingsHistoryEntry(id: "synthetic-\(i)", dayKey: "2026-11-01", recordingID: "synthetic-\(i)", createdAt: date, transcript: transcript, audioPath: directory.appendingPathComponent("nonexistent-\(i).wav"), durationMs: 126000, transcribedDurationMs: 120000, spokenDurationMs: 73000, processingDurationMs: 4200, modelLabel: "Whisper large-v3", performanceEffort: .accurate, inputDeviceLabel: "Synthetic microphone", missingTranscript: missing)
                    entries.append(entry)
                }
            }
            let page = SettingsHistoryPage(groups: entries.isEmpty ? [] : [.init(dayKey: "2026-11-01", date: Date(timeIntervalSince1970: 1793512800), entries: entries)], hasMore: true)
            let asks = SettingsAskHistoryPage(groups: [], hasMore: false)
            let view = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 }, historyPage: { _ in page }, initialHistoryPage: page, askHistoryPage: { _ in asks }, historySearchPage: { _, _ in page }, askHistorySearchPage: { _, _ in asks }, searchPrewarm: {}, initialAskHistoryPage: asks, historyRunLog: { SettingsHistoryRunLog() }, historyDiagnostics: { url in SettingsHistoryDiagnostics.load(audioPath: url, root: directory) }, initialTab: .history, historyDetailsInitiallyExpanded: name == "expanded", speechHistoryRoot: directory.appendingPathComponent("empty-speech"), historyPlayback: SettingsAudioPlayback(start: { _ in XCTFail("No audio start allowed"); return false }, stop: {}, canPlay: { false }))
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            if name == "expanded", let scroll = Self.scrollViews(host).last, let document = scroll.documentView {
                let y = max(0, document.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
            XCTAssertFalse(window.isVisible)
            window.contentView = nil
        }
    }

    func testSyntheticTranscriptionControlsSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["ASK5_SNAPSHOT_OUTPUT"] else { throw XCTSkip("ASK5_SNAPSHOT_OUTPUT required") }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let health: [String: Any] = ["type": "health", "recording_state": "idle", "model_status": [
            "configured_model": ["name": "large-v3-turbo", "size_bytes": 1_600_000_000, "installed": true],
            "residency": "loaded", "active_model": "large-v3-turbo", "configured_effort": "accurate", "active_effort": "accurate"],
            "polish_controls": ["model_polish": ["source": "default", "raw": NSNull(), "effective": "off"],
                                "outro_gate": ["source": "default", "raw": NSNull(), "effective": false],
                                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": true]]]
        let state = ModelsSettingsState(healthEvent: health)
        let host = NSHostingView(rootView: ModelsSettingsView(state: state, onToggleProcessing: { _, _ in XCTFail("Snapshot must not change settings") }).frame(width: 650, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 650, height: 620)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("controls.png"))
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
    }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
