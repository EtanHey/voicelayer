import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane E (QA 2.2.25 C10/C15): "still some lag when I click Dictations… and Ask" and "clicking History… that was
/// long". Opt-in timing evidence on a synthetic archive with the real archive's SHAPE: a manifest of
/// `day \t entry \t source \t transcriptChars \t durationMs \t hasTranscript \t hasAgentTranscript` rows (no text).
/// Transcripts are synthetic filler of the recorded length.
///
/// Run: `VOICELAYER_HISTORY_BENCH_SHAPE=<manifest.tsv> swift test --filter HistoryOpenAndScopeSwitchBenchmarkTests`
@MainActor
final class HistoryOpenAndScopeSwitchBenchmarkTests: XCTestCase {
    private static var shapePath: String? {
        ProcessInfo.processInfo.environment["VOICELAYER_HISTORY_BENCH_SHAPE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Read-only timing against an existing archive (nothing is written, printed or kept from it).
    private static var existingRoot: URL? {
        ProcessInfo.processInfo.environment["VOICELAYER_HISTORY_BENCH_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var root: URL!
    private var ownsRoot = false

    override func setUpWithError() throws {
        if let existing = Self.existingRoot {
            root = existing
            print("HISTORY_BENCH archive=existing (read-only)")
            return
        }
        guard let shapePath = Self.shapePath else {
            throw XCTSkip("Set VOICELAYER_HISTORY_BENCH_SHAPE to a shape manifest to run lane E timing evidence")
        }
        ownsRoot = true
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-bench-\(UUID().uuidString)", isDirectory: true)
        let count = try Self.buildSyntheticArchive(shape: shapePath, root: root)
        print("HISTORY_BENCH archive_entries=\(count)")
    }

    override func tearDownWithError() throws {
        if ownsRoot, let root { try? FileManager.default.removeItem(at: root) }
    }

    func testIndexPageTimings() async {
        let index = SettingsArchiveIndex()
        let coldDictations = await timed { await index.dictationPage(from: self.root) }
        let coldAsk = await timed { await index.askPage(from: self.root) }
        let warmDictations = await timed { await index.dictationPage(from: self.root) }
        let warmAsk = await timed { await index.askPage(from: self.root) }
        let fresh = SettingsArchiveIndex()
        let coldAskFirst = await timed { await fresh.askPage(from: self.root) }
        print(String(
            format: "HISTORY_BENCH index cold_dictations_ms=%.1f cold_ask_after_dictations_ms=%.1f "
                + "warm_dictations_ms=%.1f warm_ask_ms=%.1f cold_ask_first_ms=%.1f",
            coldDictations.ms, coldAsk.ms, warmDictations.ms, warmAsk.ms, coldAskFirst.ms
        ))
        XCTAssertEqual(coldDictations.value.loadedEntryCount, SettingsHistoryArchive.defaultPageSize)
        XCTAssertGreaterThan(coldAsk.value.loadedEntryCount, 0)
    }

    /// First History open (cold index) until the first page's rows are rendered, and each scope switch until the
    /// switched-to list is rendered, as the user sees them in a hosted Settings window.
    func testHostedHistoryOpenAndScopeSwitches() throws {
        let index = SettingsArchiveIndex()
        let probe = LoadProbe()
        let archiveRoot = try XCTUnwrap(root)
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil }, onSelectDevice: { _ in },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                let page = await index.dictationPage(from: archiveRoot, limit: limit)
                probe.mark("dictations")
                return page
            },
            askHistoryPage: { limit in
                let page = await index.askPage(from: archiveRoot, limit: limit)
                probe.mark("ask")
                return page
            },
            searchPrewarm: {},
            initialTab: .history
        )

        let start = CFAbsoluteTimeGetCurrent()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let open = settle(after: start, waitingFor: "dictations", probe: probe)
        print(String(format: "HISTORY_BENCH open first_rows_ms=%.1f loader_done_ms=%.1f longest_main_stall_ms=%.1f",
                     open.quietAtMs, open.loaderDoneMs, open.longestStallMs))
        // Let the Ask prefetch the Dictations load starts finish, as it would while the user reads the list.
        _ = settle(after: CFAbsoluteTimeGetCurrent(), waitingFor: "ask", probe: probe)

        let segmented = try XCTUnwrap(firstSegmentedControl(in: host))
        for (label, segment, key) in [("to_ask", 1, "ask"), ("to_dictations", 0, "dictations"),
                                      ("to_ask_again", 1, "ask"), ("to_dictations_again", 0, "dictations")] {
            probe.reset(key)
            let clickedAt = CFAbsoluteTimeGetCurrent()
            segmented.selectedSegment = segment
            _ = segmented.sendAction(segmented.action, to: segmented.target)
            let result = settle(after: clickedAt, waitingFor: key, probe: probe)
            print(String(
                format: "HISTORY_BENCH switch %@ settled_ms=%.1f loader_done_ms=%.1f longest_main_stall_ms=%.1f",
                label,
                result.quietAtMs,
                result.loaderDoneMs,
                result.longestStallMs
            ))
        }
    }

    /// Etan's path: Settings already open on General, then History clicked in the sidebar (cold index).
    func testHostedClickHistoryFromGeneral() throws {
        let index = SettingsArchiveIndex()
        let probe = LoadProbe()
        let archiveRoot = try XCTUnwrap(root)
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil }, onSelectDevice: { _ in },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                let page = await index.dictationPage(from: archiveRoot, limit: limit)
                probe.mark("dictations")
                return page
            },
            askHistoryPage: { limit in
                let page = await index.askPage(from: archiveRoot, limit: limit)
                probe.mark("ask")
                return page
            },
            searchPrewarm: {},
            initialTab: .general
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        probe.mark("mounted")
        _ = settle(after: CFAbsoluteTimeGetCurrent(), waitingFor: "mounted", probe: probe)
        let table = try XCTUnwrap(firstTable(in: host))
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))

        let clickedAt = CFAbsoluteTimeGetCurrent()
        table.selectRowIndexes([history], byExtendingSelection: false)
        let result = settle(after: clickedAt, waitingFor: "dictations", probe: probe)
        print(String(
            format: "HISTORY_BENCH click_history first_rows_ms=%.1f loader_done_ms=%.1f longest_main_stall_ms=%.1f",
            result.quietAtMs,
            result.loaderDoneMs,
            result.longestStallMs
        ))

        // Away and back, warm (the "reopening History is slow even though I was just there" case).
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        table.selectRowIndexes([general], byExtendingSelection: false)
        _ = settle(after: CFAbsoluteTimeGetCurrent(), waitingFor: "mounted", probe: probe)
        probe.reset("dictations")
        let againAt = CFAbsoluteTimeGetCurrent()
        table.selectRowIndexes([history], byExtendingSelection: false)
        let again = settle(after: againAt, waitingFor: "dictations", probe: probe)
        print(String(
            format: "HISTORY_BENCH click_history_again first_rows_ms=%.1f loader_done_ms=%.1f longest_main_stall_ms=%.1f",
            again.quietAtMs,
            again.loaderDoneMs,
            again.longestStallMs
        ))
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    // MARK: - Measurement helpers

    private final class LoadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [String: CFAbsoluteTime] = [:]
        func mark(_ key: String) {
            lock.lock()
            marks[key] = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        }

        func reset(_ key: String) {
            lock.lock()
            marks[key] = nil
            lock.unlock()
        }

        func time(_ key: String) -> CFAbsoluteTime? {
            lock.lock()
            defer { lock.unlock() }
            return marks[key]
        }
    }

    private struct Settled {
        let quietAtMs: Double
        let loaderDoneMs: Double
        let longestStallMs: Double
    }

    /// Spins the main run loop in 2 ms slices. A slice that takes far longer is main-thread work (state apply,
    /// body, layout, render). "Settled" = the loader has returned and 150 ms have passed with no slice over 8 ms.
    private func settle(after start: CFAbsoluteTime, waitingFor key: String, probe: LoadProbe,
                        timeout: TimeInterval = 10) -> Settled {
        var longest = 0.0
        var lastBusyEnd = start
        let deadline = start + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            let sliceStart = CFAbsoluteTimeGetCurrent()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let sliceEnd = CFAbsoluteTimeGetCurrent()
            let sliceMs = (sliceEnd - sliceStart) * 1000
            if sliceMs > 8 {
                longest = max(longest, sliceMs)
                lastBusyEnd = sliceEnd
            }
            // A switch that needs no load (the scope stayed mounted) settles once the main thread is quiet.
            let done = probe.time(key)
            if sliceEnd - max(lastBusyEnd, done ?? start) > 0.15, done != nil || sliceEnd - start > 0.4 {
                return Settled(
                    quietAtMs: (max(lastBusyEnd, done ?? start) - start) * 1000,
                    loaderDoneMs: done.map { ($0 - start) * 1000 } ?? -1,
                    longestStallMs: longest
                )
            }
        }
        return Settled(quietAtMs: timeout * 1000, loaderDoneMs: -1, longestStallMs: longest)
    }

    private func timed<T>(_ work: () async -> T) async -> (value: T, ms: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = await work()
        return (value, (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = firstSegmentedControl(in: subview) { return control }
        }
        return nil
    }

    // MARK: - Synthetic archive

    static func buildSyntheticArchive(shape: String, root: URL) throws -> Int {
        let rows = try String(contentsOfFile: shape, encoding: .utf8).split(separator: "\n")
        let fm = FileManager.default
        let wav = Data(count: 44)
        let filler = String(repeating: "synthetic words for a benchmark row ", count: 400)
        var count = 0
        for row in rows {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let (day, entry, source) = (fields[0], fields[1], fields[2])
            let chars = min(Int(fields[3]) ?? 0, filler.count)
            let duration = Int(fields[4]) ?? 0
            let dir = root.appendingPathComponent(day).appendingPathComponent(entry)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try wav.write(to: dir.appendingPathComponent("audio.wav"))
            let metadata: [String: Any] = [
                "id": entry, "source": source, "duration_ms": duration, "transcribed_duration_ms": duration,
                "transcription_status": "transcribed",
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(to: dir.appendingPathComponent("metadata.json"))
            if fields[5] == "1" {
                try String(filler.prefix(max(chars, 1)))
                    .write(
                        to: dir.appendingPathComponent("voicelayer-transcript.txt"),
                        atomically: false,
                        encoding: .utf8
                    )
            }
            if fields[6] == "1" {
                try String(filler.prefix(240))
                    .write(to: dir.appendingPathComponent("agent-transcript.txt"), atomically: false, encoding: .utf8)
            }
            count += 1
        }
        return count
    }
}
