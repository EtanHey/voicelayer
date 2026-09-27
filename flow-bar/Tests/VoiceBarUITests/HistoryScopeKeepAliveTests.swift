import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane E (QA 2.2.25 C10): switching Dictations ↔ Ask rebuilt the whole list and reloaded it on every click.
/// Each scope now mounts the first time it is shown in a History visit and stays mounted (hidden) after, keeping
/// itself current, so switching back is a visibility change, not a rebuild and reload.
@MainActor
final class HistoryScopeKeepAliveTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func hit(_ key: String) {
            lock.lock()
            counts[key, default: 0] += 1
            lock.unlock()
        }

        func count(_ key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[key, default: 0]
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-keepalive-\(UUID().uuidString)", isDirectory: true)
        for (entry, source) in [
            ("2026-09-27T10-00-00-000Z-a", "voicebar"),
            ("2026-09-27T10-01-00-000Z-b", "voice_ask"),
        ] {
            let dir = root.appendingPathComponent("2026-09-27").appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
            try "Synthetic fixture text".write(to: dir.appendingPathComponent("voicelayer-transcript.txt"),
                                               atomically: true, encoding: .utf8)
            try #"{"source":"\#(source)","duration_ms":1000}"#.write(
                to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8
            )
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func host(counter: Counter) -> (NSWindow, NSHostingView<SettingsView>) {
        let index = SettingsArchiveIndex()
        let archive = root!
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                counter.hit("dictations")
                return await index.dictationPage(from: archive, limit: limit)
            },
            askHistoryPage: { limit in
                counter.hit("ask")
                return await index.askPage(from: archive, limit: limit)
            },
            searchPrewarm: {},
            initialTab: .history
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        return (window, host)
    }

    func testReturningToAScopeAlreadyShownDoesNotReloadIt() throws {
        let counter = Counter()
        let (window, host) = host(counter: counter)
        defer { window.orderOut(nil)
            window.contentView = nil
        }
        XCTAssertTrue(settle { counter.count("dictations") >= 1 && counter.count("ask") >= 1 }, "open + Ask prefetch")
        let segmented = try XCTUnwrap(firstSegmentedControl(in: host))

        select(segmented, 1)
        XCTAssertTrue(settle { counter.count("ask") >= 2 }, "the first Ask visit loads")
        pause()
        let (dictations, ask) = (counter.count("dictations"), counter.count("ask"))

        select(segmented, 0)
        pause()
        select(segmented, 1)
        pause()
        select(segmented, 0)
        pause()

        XCTAssertEqual(counter.count("dictations"), dictations, "Dictations stayed mounted: no reload")
        XCTAssertEqual(counter.count("ask"), ask, "Ask stayed mounted: no reload")
    }

    func testAHiddenScopeStillPicksUpAnArchiveChange() throws {
        let counter = Counter()
        let (window, host) = host(counter: counter)
        defer { window.orderOut(nil)
            window.contentView = nil
        }
        XCTAssertTrue(settle { counter.count("ask") >= 1 })
        let segmented = try XCTUnwrap(firstSegmentedControl(in: host))
        select(segmented, 1)
        XCTAssertTrue(settle { counter.count("ask") >= 2 })
        pause()
        let dictations = counter.count("dictations")

        // A new dictation lands while Ask is on screen.
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)

        XCTAssertTrue(settle { counter.count("dictations") > dictations },
                      "the hidden Dictations list reloads itself, so switching back shows it current")
    }

    func testLeavingHistoryResetsSoTheOtherScopeReloadsOnReturn() throws {
        let counter = Counter()
        let (window, host) = host(counter: counter)
        defer { window.orderOut(nil)
            window.contentView = nil
        }
        XCTAssertTrue(settle { counter.count("ask") >= 1 })
        let segmented = try XCTUnwrap(firstSegmentedControl(in: host))
        select(segmented, 1)
        XCTAssertTrue(settle { counter.count("ask") >= 2 })
        select(segmented, 0)
        pause()

        // Away to General (both lists unmount and stop listening) and back.
        let table = try XCTUnwrap(firstTable(in: host))
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))
        table.selectRowIndexes([general], byExtendingSelection: false)
        pause()
        table.selectRowIndexes([history], byExtendingSelection: false)
        pause()
        let ask = counter.count("ask")
        let segmentedAgain = try XCTUnwrap(firstSegmentedControl(in: host))
        select(segmentedAgain, 1)

        XCTAssertTrue(settle { counter.count("ask") > ask }, "Ask missed changes while unmounted, so it reloads")
    }

    // MARK: - Helpers

    private func select(_ segmented: NSSegmentedControl, _ segment: Int) {
        segmented.selectedSegment = segment
        _ = segmented.sendAction(segmented.action, to: segmented.target)
    }

    private func pause(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = firstSegmentedControl(in: subview) { return control }
        }
        return nil
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}
