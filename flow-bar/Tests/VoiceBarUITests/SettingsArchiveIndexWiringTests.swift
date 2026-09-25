import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// R4/H1-a2: History loads through `SettingsArchiveIndex`; the app invalidates a re-transcribed entry before
/// reloading and releases the index when Settings closes. Memory stays flat across open/close cycles, and the
/// opt-in benchmark times a switch and a reopen on an ~11k-entry archive.
final class SettingsArchiveIndexWiringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMemoryStaysFlatAcrossOpenCloseCycles() async throws {
        for hour in 0 ..< 400 {
            try writeDictation(day: "2026-09-\(10 + hour % 10)", id: "m\(hour)",
                               createdAt: "2026-09-\(10 + hour % 10)T00:00:00.000Z",
                               transcript: String(repeating: "word ", count: 60))
        }
        let index = SettingsArchiveIndex()
        var residentAfterCycle: [UInt64] = []
        for _ in 0 ..< 5 {
            _ = await index.dictationPage(from: root, limit: 400)
            _ = await index.askPage(from: root, limit: 400)
            await index.release()
            residentAfterCycle.append(Self.residentBytes())
        }
        let growth = Int64(residentAfterCycle[4]) - Int64(residentAfterCycle[1])
        XCTAssertLessThan(growth, 8 * 1024 * 1024, "resident memory must not grow per Settings open/close cycle")
        let cached = await index.cachedRootCount()
        XCTAssertEqual(cached, 0)
    }

    /// #153 review MUST-FIX 1 (P09b follow-up 3, R1): the Settings window is reused, so closing it hides the
    /// view without tearing it down. A hidden History view still hears `.voiceBarHistoryArchiveDidChange` and
    /// reloads through the index, refilling it after every dictation. Closing must drop the view, then release.
    @MainActor
    func testClosingSettingsDropsTheViewSoAnArchiveChangeCannotRefillTheIndex() async throws {
        try writeDictation(day: "2026-09-20", id: "a", createdAt: "2026-09-20T08:00:00.000Z", transcript: "one")
        let index = SettingsArchiveIndex()
        let root = try XCTUnwrap(root)
        let loads = LoadCounter()
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { limit in
                loads.increment()
                return await index.dictationPage(from: root, limit: limit)
            },
            askHistoryPage: { limit in await index.askPage(from: root, limit: limit) },
            initialTab: .history
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()

        let firstLoad = await settle { loads.value >= 1 }
        XCTAssertTrue(firstLoad, "History loads when it appears")
        // Control: while hosted, an archive change reloads through the index (the mechanism of the bug).
        let beforeChange = loads.value
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        let reloaded = await settle { loads.value > beforeChange }
        XCTAssertTrue(reloaded, "the control failed: a hosted History view must reload on an archive change")

        await SettingsWindowLifecycle.settingsWindowWillClose(window, index: index)
        XCTAssertNil(window.contentViewController, "closing drops the hosting controller; reopen rebuilds it")
        let afterClose = loads.value

        // Dictating with Settings closed: the change must not reach a hidden view.
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        let reloadedWhileClosed = await settle(timeout: .milliseconds(900)) { loads.value > afterClose }
        XCTAssertFalse(reloadedWhileClosed, "a closed Settings window must not reload History")
        let cached = await index.cachedRootCount()
        XCTAssertEqual(cached, 0, "the index stays empty while Settings is closed")
    }

    @MainActor
    func testReopeningRebuildsTheViewOnceAtTheSizeTheUserLeft() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        var built = 0
        let make = {
            built += 1
            return SettingsView(
                hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                onSelectDevice: { _ in }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyRevision: { 0 }, historyPage: { _ in SettingsHistoryPage(groups: [], hasMore: false) },
                askHistoryPage: { _ in SettingsAskHistoryPage(groups: [], hasMore: false) }
            )
        }
        SettingsWindowLifecycle.rebuildContentIfNeeded(window, makeSettingsView: make)
        let userFrame = NSRect(x: 40, y: 60, width: 910, height: 640)
        window.setFrame(userFrame, display: false)

        SettingsWindowLifecycle.rebuildContentIfNeeded(window, makeSettingsView: make)
        XCTAssertEqual(built, 1, "an open window keeps its view")

        await SettingsWindowLifecycle.settingsWindowWillClose(window, index: SettingsArchiveIndex())
        SettingsWindowLifecycle.rebuildContentIfNeeded(window, makeSettingsView: make)
        XCTAssertEqual(built, 2)
        XCTAssertNotNil(window.contentViewController as? NSHostingController<SettingsView>)
        XCTAssertEqual(window.frame, userFrame)
    }

    /// #153 review MUST-FIX 2: the first Dictations→Ask switch walked the Ask scope cold (304.7 ms on the real
    /// archive). Once the Dictations page lands, the Ask page is prefetched in the background: after it, never
    /// racing it, so it cannot slow the page the user is looking at.
    @MainActor
    func testTheAskPageIsPrefetchedAfterTheDictationsPageLands() async {
        let log = EventLog()
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in
                log.append("dictations-start")
                try? await Task.sleep(for: .milliseconds(50))
                log.append("dictations-end")
                return SettingsHistoryPage(groups: [], hasMore: false)
            },
            askHistoryPage: { _ in
                log.append("ask")
                return SettingsAskHistoryPage(groups: [], hasMore: false)
            },
            initialTab: .history
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()

        let prefetched = await settle { log.events.contains("ask") }
        XCTAssertTrue(prefetched, "the Ask page is loaded before the user switches to it")
        let events = log.events
        XCTAssertEqual(Array(events.prefix(3)), ["dictations-start", "dictations-end", "ask"])
        window.contentViewController = nil
    }

    // MARK: - Wiring pins (the app target is not importable from these tests)

    func testHistoryLoadsGoThroughTheSharedIndexByDefault() throws {
        let source = try sourceFile("VoiceBarUI/SettingsView.swift")

        XCTAssertTrue(source.contains("public let historyPage: @Sendable (Int) async -> SettingsHistoryPage"))
        XCTAssertTrue(source.contains("public let askHistoryPage: @Sendable (Int) async -> SettingsAskHistoryPage"))
        XCTAssertTrue(source.contains("await SettingsArchiveIndex.shared.dictationPage(limit: limit)"))
        XCTAssertTrue(source.contains("await SettingsArchiveIndex.shared.askPage(limit: limit)"))
        XCTAssertFalse(source.contains("= { limit in\n            SettingsHistoryArchive.loadPage(limit: limit)"))
        XCTAssertEqual(source.components(separatedBy: "let page = await loader(limit)").count - 1, 2)
    }

    func testTheAppInvalidatesBeforeReloadingAndReleasesTheIndexWhenSettingsCloses() throws {
        let app = try sourceFile("VoiceBar/VoiceBarApp.swift")

        XCTAssertTrue(app
            .contains("historyPage: { limit in await SettingsArchiveIndex.shared.dictationPage(limit: limit) }"))
        XCTAssertTrue(app.contains("await SettingsArchiveIndex.shared.invalidate(entryPath: path)"))
        let invalidate = try XCTUnwrap(app.range(of: "await SettingsArchiveIndex.shared.invalidate(entryPath: path)"))
        let post = try XCTUnwrap(app
            .range(of: "NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange"))
        XCTAssertLessThan(invalidate.lowerBound, post.lowerBound, "the reload must not read the stale entry")
        XCTAssertTrue(app.contains("window.delegate = self"))
        XCTAssertTrue(app.contains("SettingsWindowLifecycle.settingsWindowWillClose(window)"))
        XCTAssertTrue(app.contains("SettingsWindowLifecycle.rebuildContentIfNeeded("))
    }

    private func sourceFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Timing evidence (opt-in)

    /// Kickoff target: a Recording↔Ask switch and a History reopen under 300 ms on a ~11k-entry archive.
    /// Synthetic 11k archive always; the real archive read-only (counts only) when it exists.
    func testSwitchAndReopenTimingOnAnElevenThousandEntryArchive() async throws {
        guard ProcessInfo.processInfo.environment["VOICELAYER_SETTINGS_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICELAYER_SETTINGS_PERF_BENCHMARK=1 to run timing evidence")
        }
        for index in 0 ..< 11000 {
            let day = String(format: "2026-%02d-%02d", 1 + index / 3000 % 9, 1 + index % 28)
            let createdAt = "\(day)T\(String(format: "%02d", index % 24)):00:00.000Z"
            if index % 10 == 0 {
                try writeAsk(
                    day: day,
                    id: String(format: "q%05d", index),
                    createdAt: createdAt,
                    question: "Question \(index)?"
                )
            } else {
                try writeDictation(day: day, id: String(format: "d%05d", index), createdAt: createdAt,
                                   transcript: "Synthetic dictation \(index)")
            }
        }
        try await report(root: root, label: "synthetic")
        let real = SettingsHistoryArchive.defaultRoot
        if FileManager.default.fileExists(atPath: real.path) {
            try await report(root: real, label: "real-readonly")
        }
    }

    /// Models what the app does: open History (cold Dictations page), prefetch Ask behind it, switch, switch back;
    /// then close (`release()`) and reopen cold, twice. `cold_ask_page_ms` is the Ask walk with no prefetch.
    private func report(root: URL, label: String) async throws {
        func ms(_ start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func timed<T>(_ body: () async -> T) async -> (T, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = await body()
            return (value, ms(start))
        }
        let index = SettingsArchiveIndex()
        let (_, coldAskPage) = await timed { await index.askPage(from: root, limit: 100) }
        await index.release()

        var line = "H1A_INDEX \(label)"
        var worstOpen = 0.0
        var worstFirstAskSwitch = 0.0
        for cycle in 0 ..< 3 {
            let (first, open) = await timed { await index.dictationPage(from: root, limit: 100) }
            let (asks, prefetch) = await timed { await index.askPage(from: root, limit: 100) }
            let (_, firstAskSwitch) = await timed { await index.askPage(from: root, limit: 100) }
            let (_, switchBack) = await timed { await index.dictationPage(from: root, limit: 100) }
            await index.release()
            let cached = await index.cachedRootCount()
            XCTAssertEqual(cached, 0, "close releases the index")
            if cycle == 0 {
                line += " dictations=\(first.loadedEntryCount) asks=\(asks.loadedEntryCount)"
                    + String(format: " cold_ask_page_ms=%.1f", coldAskPage)
            }
            line += String(
                format: " | open%d_ms=%.1f ask_prefetch_ms=%.1f first_ask_switch_ms=%.1f switch_back_ms=%.1f",
                cycle, open, prefetch, firstAskSwitch, switchBack
            )
            worstOpen = max(worstOpen, open)
            worstFirstAskSwitch = max(worstFirstAskSwitch, firstAskSwitch)
            XCTAssertLessThan(switchBack, 300)
        }
        print(line)
        XCTAssertLessThan(worstOpen, 300, "a (re)open after release is cold and must still be < 300 ms")
        XCTAssertLessThan(worstFirstAskSwitch, 300, "the first Ask switch after the prefetch")
        if label == "synthetic" {
            XCTAssertLessThan(coldAskPage, 300, "even unprefetched, the synthetic Ask walk stays < 300 ms")
        }
    }

    // MARK: - Fixtures

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

    private func writeAsk(day: String, id: String, createdAt: String, question: String) throws {
        let dir = root.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try question.write(to: dir.appendingPathComponent("agent-transcript.txt"), atomically: true, encoding: .utf8)
        try "an answer".write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id": "\#(id)", "created_at": "\#(createdAt)", "source": "\#(SettingsArchiveSchema.askSourceValue)"}"#
            .write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Counts loader calls from the detached History load task.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}
