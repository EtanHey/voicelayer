import OffscreenTestSupport
import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA-06 fix round (Etan 2026-11-02: "the state is not kept between just traveling within the app"):
/// leaving History and coming back restores the list's and the detail pane's ACTUAL visible positions,
/// independent of the selected row. Scrolling here moves the real NSScrollView clip views without
/// selecting anything, exactly as a trackpad scroll would.
@MainActor
final class HistoryScrollRestoreTests: XCTestCase {
    private var root: URL!
    private static let rows = 40

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-scroll-\(UUID().uuidString)", isDirectory: true)
        let long = Array(repeating: "Synthetic words fill this long dictation so its detail pane must scroll.", count: 60)
            .joined(separator: " ")
        for index in 0..<Self.rows {
            let minute = String(format: "%02d", index)
            let entry = "2026-09-27T10-\(minute)-00-000Z-\(index)"
            let dir = root.appendingPathComponent("2026-09-27").appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
            try "Row \(index). \(long)".write(to: dir.appendingPathComponent("voicelayer-transcript.txt"),
                                               atomically: true, encoding: .utf8)
            try #"{"source":"voicebar","duration_ms":1000}"#.write(
                to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testLeavingAndReturningRestoresListAndDetailScrollPositionsNotTheSelection() throws {
        let archive = root!
        let index = SettingsArchiveIndex()
        // Opened with its first page already in hand, as on re-entry: no programmatic scroll-to-newest is
        // pending in the list, so the direct clip-view scrolls below stand in for a user's scroll.
        let loaded = expectation(description: "first page")
        nonisolated(unsafe) var firstPage: SettingsHistoryPage?
        Task { firstPage = await index.dictationPage(from: archive, limit: 100); loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in await index.dictationPage(from: archive, limit: limit) },
            initialHistoryPage: firstPage,
            askHistoryPage: { limit in await index.askPage(from: archive, limit: limit) },
            searchPrewarm: {},
            initialTab: .history
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        VLOrderTestWindow(window)
        defer { window.orderOut(nil); window.contentView = nil }

        XCTAssertTrue(settle { historyScrollViews(in: host).list.map(scrollableHeight) ?? 0 > 400 },
                      "the 40-row list loads and can scroll")
        XCTAssertTrue(settle { historyScrollViews(in: host).detail.map(scrollableHeight) ?? 0 > 300 },
                      "the selected long dictation's detail pane can scroll")

        var (list, detail) = historyScrollViews(in: host)
        scroll(try XCTUnwrap(list), to: 400)
        scroll(try XCTUnwrap(detail), to: 260)
        pause()
        XCTAssertEqual(try XCTUnwrap(list).contentView.bounds.origin.y, 400, accuracy: 1)

        // Away to General (the History subtree unmounts) and back.
        let table = try XCTUnwrap(firstTable(in: host))
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))
        table.selectRowIndexes([general], byExtendingSelection: false)
        pause()
        XCTAssertNil(historyScrollViews(in: host).list, "History really left the hierarchy")
        table.selectRowIndexes([history], byExtendingSelection: false)

        XCTAssertTrue(settle { historyScrollViews(in: host).list != nil && historyScrollViews(in: host).detail != nil })
        pause(0.8) // the re-entry page load lands and lays out
        (list, detail) = historyScrollViews(in: host)
        XCTAssertEqual(try XCTUnwrap(list).contentView.bounds.origin.y, 400, accuracy: 2,
                       "the list returns where it was left, not at the selected (newest) row")
        XCTAssertEqual(try XCTUnwrap(detail).contentView.bounds.origin.y, 260, accuracy: 2,
                       "the detail pane returns where it was left")
    }

    // MARK: - Helpers

    /// The two History scroll views: the list (left) and the selected dictation's detail (right).
    /// The Settings sidebar's table scroll view is excluded.
    private func historyScrollViews(in host: NSView) -> (list: NSScrollView?, detail: NSScrollView?) {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !(scroll.documentView is NSTableView), !scroll.isHiddenOrHasHiddenAncestor,
               scroll.frame.width > 100 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(host)
        let sorted = found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard sorted.count >= 2 else { return (nil, nil) }
        return (sorted[0], sorted[1])
    }

    private func scrollableHeight(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
    }

    /// Moves the real clip view, as a trackpad scroll ends up doing, without selecting anything.
    /// (Scroll-wheel events don't reach SwiftUI's scroll handling in an offscreen window.)
    private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    private func pause(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func settle(timeout: TimeInterval = 6, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let table = firstTable(in: subview) { return table } }
        return nil
    }
}

/// The keeper on its own, in a plain AppKit scroll view: what it records, what it ignores, and that it
/// restores once the content is tall enough.
@MainActor
final class SettingsHistoryScrollKeeperTests: XCTestCase {
    func testMemoryKeepsTheListAndOnlyTheLatestDetail() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        memory.record(120, for: .detail("a"))
        memory.record(80, for: .detail("b"))
        XCTAssertEqual(memory.offset(for: .list), 400)
        XCTAssertNil(memory.offset(for: .detail("a")), "another recording's detail starts at its top")
        XCTAssertEqual(memory.offset(for: .detail("b")), 80)
        memory.record(-5, for: .list)
        XCTAssertEqual(memory.offset(for: .list), 0, "rubber-band overscroll is never kept")
    }

    func testKeeperRecordsUserScrollsAndRestoresThemIntoARebuiltScrollView() {
        let memory = SettingsHistoryScrollMemory()
        let first = scrollView(height: 2000)
        let keeper = SettingsHistoryScrollKeeper.KeeperView(memory: memory, key: .list)
        first.scroll.documentView?.addSubview(keeper)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(keeper.hasRestored, "nothing remembered: recording starts at once")
        first.scroll.contentView.scroll(to: NSPoint(x: 0, y: 650))
        XCTAssertEqual(memory.offset(for: .list), 650)

        keeper.removeFromSuperview() // leaving History
        first.scroll.contentView.scroll(to: .zero)
        XCTAssertEqual(memory.offset(for: .list), 650, "teardown never overwrites the user's position")

        // Returning: a new scroll view whose content is still short, then grows (a lazy list laying out).
        let second = scrollView(height: 300)
        let rebuilt = SettingsHistoryScrollKeeper.KeeperView(memory: memory, key: .list)
        second.scroll.documentView?.addSubview(rebuilt)
        XCTAssertFalse(rebuilt.hasRestored, "waits for content tall enough to hold the position")
        XCTAssertEqual(memory.offset(for: .list), 650)
        second.scroll.documentView?.setFrameSize(NSSize(width: 300, height: 2000))
        let deadline = Date().addingTimeInterval(2)
        while !rebuilt.hasRestored, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(second.scroll.contentView.bounds.origin.y, 650, accuracy: 0.5)
        _ = (first.window, second.window)
    }

    /// Round-2 review (ship-blocker): the user scrolls while the keeper is still waiting for content.
    /// Their position wins; growing content never yanks them back to the remembered offset.
    func testAUserScrollDuringTheWaitCancelsTheRestore() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 900) // 500 reachable: too short for 650
        let keeper = SettingsHistoryScrollKeeper.KeeperView(memory: memory, key: .list)
        view.scroll.documentView?.addSubview(keeper)
        XCTAssertFalse(keeper.hasRestored, "waiting for content")
        userScroll(view.scroll, by: 200)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5, "the user's wheel scroll landed")
        view.scroll.documentView?.setFrameSize(NSSize(width: 300, height: 2000))
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5, "no jump back to 650")
        XCTAssertEqual(memory.offset(for: .list), 200, "the user's position is what is remembered now")
        _ = view.window
    }

    /// Content never grows tall enough within the wait: the keeper gives up without a late jump.
    func testTimingOutLeavesThePositionWhereItWas() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 600) // 200 reachable, and it stays that way
        let keeper = SettingsHistoryScrollKeeper.KeeperView(memory: memory, key: .list)
        view.scroll.documentView?.addSubview(keeper)
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        XCTAssertTrue(keeper.hasRestored, "the wait ended")
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "no late jump to the clamped offset")
        _ = view.window
    }

    /// A real pixel scroll-wheel event handed to the AppKit scroll view (nothing is posted to the system).
    private func userScroll(_ scroll: NSScrollView, by delta: CGFloat) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(-delta), wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return XCTFail("no scroll event") }
        scroll.scrollWheel(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func scrollView(height: CGFloat) -> (window: NSWindow, scroll: NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = scroll
        return (window, scroll)
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
