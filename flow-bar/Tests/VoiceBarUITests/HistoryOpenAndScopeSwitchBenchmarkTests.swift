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
        let probe = HistoryBenchProbe()
        let archiveRoot = try XCTUnwrap(root)
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                probe.start("dictations")
                let page = await index.dictationPage(from: archiveRoot, limit: limit)
                probe.finish("dictations")
                return page
            },
            askHistoryPage: { limit in
                probe.start("ask")
                let page = await index.askPage(from: archiveRoot, limit: limit)
                probe.finish("ask")
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
        let open = HistoryBenchSettle.settle(after: start, expecting: .load("dictations"), probe: probe)
        report("open", open)
        // Let the Ask prefetch the Dictations load starts finish, as it would while the user reads the list. A wait,
        // not a measurement (it may already be done), so it is not printed; it must still complete.
        let prefetch = HistoryBenchSettle.settle(
            after: CFAbsoluteTimeGetCurrent(), expecting: .load("ask"), probe: probe
        )
        XCTAssertFalse(prefetch.timedOut, "the Ask prefetch never completed")

        let segmented = try XCTUnwrap(firstSegmentedControl(in: host))
        for (label, segment, key) in [("to_ask", 1, "ask"), ("to_dictations", 0, "dictations"),
                                      ("to_ask_again", 1, "ask"), ("to_dictations_again", 0, "dictations")] {
            probe.reset(key)
            let clickedAt = CFAbsoluteTimeGetCurrent()
            segmented.selectedSegment = segment
            _ = segmented.sendAction(segmented.action, to: segmented.target)
            // A switch loads only if the scope has to; whether it did is part of the measurement.
            report("switch_\(label)", HistoryBenchSettle.settle(
                after: clickedAt, expecting: .loadIfStarted(key), probe: probe
            ))
        }
    }

    /// Etan's path: Settings already open on General, then History clicked in the sidebar (cold index).
    func testHostedClickHistoryFromGeneral() throws {
        let index = SettingsArchiveIndex()
        let probe = HistoryBenchProbe()
        let archiveRoot = try XCTUnwrap(root)
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                probe.start("dictations")
                let page = await index.dictationPage(from: archiveRoot, limit: limit)
                probe.finish("dictations")
                return page
            },
            askHistoryPage: { limit in
                probe.start("ask")
                let page = await index.askPage(from: archiveRoot, limit: limit)
                probe.finish("ask")
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
        _ = HistoryBenchSettle.settle(after: CFAbsoluteTimeGetCurrent(), expecting: .none, probe: probe)
        let table = try XCTUnwrap(firstTable(in: host))
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))

        let clickedAt = CFAbsoluteTimeGetCurrent()
        table.selectRowIndexes([history], byExtendingSelection: false)
        report("click_history", HistoryBenchSettle.settle(
            after: clickedAt, expecting: .load("dictations"), probe: probe
        ))

        // Away and back, warm (the "reopening History is slow even though I was just there" case). Returning to
        // History reloads the shown scope, so a completed load is required.
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        table.selectRowIndexes([general], byExtendingSelection: false)
        _ = HistoryBenchSettle.settle(after: CFAbsoluteTimeGetCurrent(), expecting: .none, probe: probe)
        probe.reset("dictations")
        let againAt = CFAbsoluteTimeGetCurrent()
        table.selectRowIndexes([history], byExtendingSelection: false)
        report("click_history_again", HistoryBenchSettle.settle(
            after: againAt, expecting: .load("dictations"), probe: probe
        ))
    }

    /// One line per measurement. A timed-out required load fails the test instead of printing a fast number.
    private func report(_ label: String, _ result: HistoryBenchSettled) {
        print("HISTORY_BENCH \(label) settled_ms=\(HistoryBenchSettle.format(result.quietAtMs)) "
            + "loader_done_ms=\(HistoryBenchSettle.format(result.loaderDoneMs)) "
            + String(format: "longest_main_stall_ms=%.1f", result.longestStallMs)
            + (result.timedOut ? " TIMED_OUT" : ""))
        XCTAssertFalse(result.timedOut, "\(label): the awaited load never completed")
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    // MARK: - Measurement helpers

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

    enum ManifestError: Error, CustomStringConvertible {
        case unsafeComponent(line: Int, field: String, value: String)
        case escapesRoot(line: Int, path: String)

        var description: String {
            switch self {
            case let .unsafeComponent(line, field, value): "manifest line \(line): unsafe \(field) \"\(value)\""
            case let .escapesRoot(line, path): "manifest line \(line): \(path) is outside the synthetic root"
            }
        }
    }

    /// `YYYY-MM-DD`, digits and dashes only.
    private static func isDay(_ value: String) -> Bool {
        let chars = Array(value)
        return chars.count == 10 && chars.enumerated().allSatisfy { index, char in
            [4, 7].contains(index) ? char == "-" : char.isASCII && char.isNumber
        }
    }

    /// One plain path component: ASCII letters, digits, `.`, `_`, `-`, starting with a letter or digit (so never
    /// `.`, `..` or hidden), and never a separator.
    private static func isEntry(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Builds a synthetic archive under `root` from a shape manifest. E review r1, M2: every row is validated
    /// before anything is written — the day must be `YYYY-MM-DD`, the entry one plain path component (no
    /// separators, `.`/`..`, or leading dot), and the joined directory must stay inside `root`. Transcripts are
    /// filler of exactly the declared length (CodeRabbit 4115144414); agent transcripts are a fixed 240
    /// characters, because the manifest records only whether one exists.
    static func buildSyntheticArchive(shape: String, root: URL) throws -> Int {
        let rows = try String(contentsOfFile: shape, encoding: .utf8).split(separator: "\n")
        let rootPath = root.standardizedFileURL.path + "/"
        var planned: [(dir: URL, source: String, chars: Int, duration: Int, transcript: Bool, agent: Bool)] = []
        for (offset, row) in rows.enumerated() {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let (day, entry) = (fields[0], fields[1])
            guard isDay(day) else {
                throw ManifestError.unsafeComponent(line: offset + 1, field: "day", value: day)
            }
            guard isEntry(entry) else {
                throw ManifestError.unsafeComponent(line: offset + 1, field: "entry", value: entry)
            }
            let dir = root.appendingPathComponent(day, isDirectory: true)
                .appendingPathComponent(entry, isDirectory: true)
            guard dir.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw ManifestError.escapesRoot(line: offset + 1, path: dir.path)
            }
            planned.append((dir, fields[2], max(Int(fields[3]) ?? 0, 0), Int(fields[4]) ?? 0,
                            fields[5] == "1", fields[6] == "1"))
        }

        let fm = FileManager.default
        let wav = Data(count: 44)
        let unit = "synthetic words for a benchmark row "
        for row in planned {
            try fm.createDirectory(at: row.dir, withIntermediateDirectories: true)
            try wav.write(to: row.dir.appendingPathComponent("audio.wav"))
            let metadata: [String: Any] = [
                "id": row.dir.lastPathComponent, "source": row.source, "duration_ms": row.duration,
                "transcribed_duration_ms": row.duration, "transcription_status": "transcribed",
            ]
            try JSONSerialization.data(withJSONObject: metadata)
                .write(to: row.dir.appendingPathComponent("metadata.json"))
            if row.transcript {
                try filler(unit, count: max(row.chars, 1))
                    .write(to: row.dir.appendingPathComponent("voicelayer-transcript.txt"),
                           atomically: false, encoding: .utf8)
            }
            if row.agent {
                try filler(unit, count: 240)
                    .write(to: row.dir.appendingPathComponent("agent-transcript.txt"),
                           atomically: false, encoding: .utf8)
            }
        }
        return planned.count
    }

    private static func filler(_ unit: String, count: Int) -> String {
        String(String(repeating: unit, count: count / unit.count + 1).prefix(count))
    }
}
