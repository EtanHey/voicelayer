import AppKit
import SwiftUI
import XCTest
@testable import VoiceBarUI

final class SettingsSpeechReasonCopyTests: XCTestCase {
    /// Generated from `src/speech-state.ts`; `src/__tests__/speech-reason-copy-guard.test.ts` keeps it current.
    private struct Fixture: Decodable { let states: [String]; let archive_statuses: [String]; let reasons: [String] }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/speech-reasons.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEveryStateAndReasonRendersASentenceOrNothing() throws {
        let fixture = try fixture()
        let rawCode = try NSRegularExpression(pattern: "^[A-Z_]+$")
        var pairs = 0
        for status in fixture.states + fixture.archive_statuses + ["some_future_state"] {
            for reason in fixture.reasons.map(Optional.some) + [nil, "SOME_FUTURE_REASON"] {
                pairs += 1
                let line = SettingsSpeechReasonCopy.sentence(status: status, reason: reason)
                let hidden = status == "completed" || reason == "PLAYBACK_COMPLETED"
                XCTAssertEqual(line == nil, hidden, "\(status) / \(reason ?? "nil")")
                guard let line else { continue }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(rawCode.firstMatch(in: line, range: range), "\(status) / \(reason ?? "nil") rendered \(line)")
                XCTAssertFalse(line.contains("_"), line)
                // No em-dashes in shipped copy, nor an en-dash standing in for one (Etan, 2026-10-31).
                XCTAssertFalse(line.contains("—") || line.contains("–"), line)
                if let reason { XCTAssertFalse(line.contains(reason), line) }
                XCTAssertTrue(line.first?.isUppercase == true, line)
                XCTAssertTrue(line.hasSuffix(".") || line.hasSuffix("…"), line)
                XCTAssertLessThanOrEqual(line.count, 60, line)
            }
        }
        XCTAssertEqual(pairs, 20 * 16)
    }

    func testEveryWireReasonHasItsOwnSentence() throws {
        let fixture = try fixture()
        XCTAssertEqual(SettingsSpeechReasonCopy.knownReasons, Set(fixture.reasons))
        let unknown = SettingsSpeechReasonCopy.sentence(status: "failed", reason: "SOME_FUTURE_REASON")
        for reason in fixture.reasons where reason != "PLAYBACK_COMPLETED" {
            for status in ["stopped", "cancelled", "failed", "interrupted", "replaced", "rejected"] {
                XCTAssertNotEqual(SettingsSpeechReasonCopy.sentence(status: status, reason: reason), unknown, "\(status) / \(reason)")
            }
        }
    }

    func testShippedCopyTable() {
        let table: [(String, String?, String?)] = [
            ("completed", "PLAYBACK_COMPLETED", nil),
            ("completed", nil, nil),
            ("stopped", "USER_STOP", "You stopped it."),
            ("cancelled", "USER_STOP", "You stopped it before any audio played."),
            ("cancelled", "USER_STOP_PREPARING", "You stopped it before any audio played."),
            ("cancelled", "USER_CANCEL", "You cancelled it."),
            ("cancelled", "QUEUE_CLEARED", "The queue was cleared before this played."),
            ("stopped", "REPLACED", "A newer read replaced this one."),
            ("replaced", "REPLACED", "A newer read replaced this one."),
            ("interrupted", "PROCESS_EXIT", "VoiceLayer shut down before this finished."),
            ("interrupted", "PROCESS_RESTART", "VoiceLayer restarted before this finished."),
            ("failed", "SYNTH_FAILED", "The voice couldn't generate this speech."),
            ("failed", "PLAYER_FAILED", "Audio playback failed."),
            ("failed", "OUTPUT_UNAVAILABLE", "Speech output failed."),
            ("failed", "REJECTED", "VoiceLayer turned this request down before playing it."),
            ("rejected", "REJECTED", "VoiceLayer turned this request down before playing it."),
            ("failed", "SPEECH_FAILED", "Speech failed before it finished."),
            ("failed", "ARCHIVE_INCOMPLETE", "This read was only partly saved."),
            ("requested", nil, "Waiting to start."),
            ("received", nil, "Waiting to start."),
            ("preparing", nil, "Preparing narration…"),
            ("playing", nil, "Playing now."),
            ("paused", nil, "Paused."),
            ("stopped", nil, "No reason was recorded."),
            ("interrupted_unknown", nil, "No reason was recorded."),
            ("failed", "SOME_FUTURE_REASON", "Ended for a reason this version doesn't recognise."),
        ]
        for (status, reason, expected) in table {
            XCTAssertEqual(SettingsSpeechReasonCopy.sentence(status: status, reason: reason), expected, "\(status) / \(reason ?? "nil")")
        }
    }

    func testCompletedArchiveRecordHasNoReasonLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: root.path + ".speech-history-v1")
        }
        for (index, (state, reason)) in [("completed", "PLAYBACK_COMPLETED"), ("stopped", "USER_STOP")].enumerated() {
            let id = "2026-10-26T12-00-0\(index)-000Z-abcdef12"
            let entry = root.appendingPathComponent("2026-10-26/" + id)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try #"{"schema_version":1,"source":"speak","id":"\#(id)","created_at":"2026-10-26T12:00:0\#(index)Z","status":"\#(state)","speech":{"state":"\#(state)","reason":"\#(reason)","generated":[]}}"#
                .write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        }
        let entries = Dictionary(uniqueKeysWithValues: SettingsSpeechHistoryArchive.load(from: root).map { ($0.status, $0) })
        XCTAssertEqual(entries["completed"]?.reason, "PLAYBACK_COMPLETED", "The raw code stays on the entry for the tooltip")
        XCTAssertNil(entries["completed"]?.reasonSentence)
        XCTAssertEqual(entries["stopped"]?.reasonSentence, "You stopped it.")
    }

    func testRawReasonIsOnlyATooltip() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Text(entry.reason"))
        XCTAssertFalse(source.contains("No status reason stored"))
        XCTAssertTrue(source.contains("if let sentence = entry.reasonSentence"))
        XCTAssertTrue(source.contains(".help(entry.reason ?? \"\")"))
    }

    /// Before/after evidence for N1-a: the expanded Details of a stopped read and a completed read.
    @MainActor
    func testReasonLinePresentationInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let label = ProcessInfo.processInfo.environment["VOICEBAR_N1A_SHOT_LABEL"] ?? "after"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: root.path + ".speech-history-v1")
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs.local/n1a")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rows = [("stopped", "USER_STOP", "Etan, the build is green and the PR is open."),
                    ("completed", "PLAYBACK_COMPLETED", "Orchestrator Claude here. Which song would you like?")]
        for (index, (state, reason, text)) in rows.enumerated() {
            let id = "2026-10-26T12-00-0\(index)-000Z-abcdef1\(index)"
            let entry = root.appendingPathComponent("2026-10-26/" + id)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            try #"{"schema_version":1,"source":"speak","id":"\#(id)","created_at":"2026-10-26T12:00:0\#(index)Z","status":"\#(state)","requested":{"voice":"Ben"},"speech":{"state":"\#(state)","reason":"\#(reason)","played_ms":4200,"generated":[{"index":0,"text":"\#(text)","voice":"Ben"}]}}"#
                .write(to: entry.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
            try text.write(to: entry.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
        }
        for (index, (state, _, _)) in rows.enumerated() {
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let view = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 }, historyPage: { _ in .init(groups: [], hasMore: false) }, askHistoryPage: { _ in .init(groups: [], hasMore: false) }, searchPrewarm: {}, initialTab: .history, initialHistoryScope: .speech, speechHistoryRoot: root, initialSpeechEntryID: "2026-10-26T12-00-0\(index)-000Z-abcdef1\(index)")
                let host = NSHostingView(rootView: view.frame(width: 900, height: 560))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
                window.contentView = host
                let settled = expectation(description: "Speech fixtures load")
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(600)); settled.fulfill() }
                wait(for: [settled], timeout: 5)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(label)-\(state)-\(name).png"))
                window.contentView = nil
            }
        }
    }
}
