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
        try assertLeavingAndReturningRestoresScrollPositions(releaseReloadImmediately: false)
    }

    func testImmediateReloadAlsoRestoresListAndDetailScrollPositions() throws {
        try assertLeavingAndReturningRestoresScrollPositions(releaseReloadImmediately: true)
    }

    private func assertLeavingAndReturningRestoresScrollPositions(releaseReloadImmediately: Bool) throws {
        let archive = root!
        let index = SettingsArchiveIndex()
        // Opened with its first page already in hand, as on re-entry: no programmatic scroll-to-newest is
        // pending in the list, so the direct clip-view scrolls below stand in for a user's scroll.
        let loaded = expectation(description: "first page")
        nonisolated(unsafe) var firstPage: SettingsHistoryPage?
        Task { firstPage = await index.dictationPage(from: archive, limit: 100); loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        let reload = HistoryReloadGate()
        defer { reload.release() }
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            historyPage: { limit in
                await reload.wait()
                let page = await index.dictationPage(from: archive, limit: limit)
                await reload.returningPage()
                return page
            },
            initialHistoryPage: firstPage,
            askHistoryPage: { limit in await index.askPage(from: archive, limit: limit) },
            searchPrewarm: {},
            initialTab: .history
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 620)
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

        host.layoutSubtreeIfNeeded()
        print("History initial layout: \(scrollDiagnostics(in: host)); backingScale=\(window.backingScaleFactor)")
        XCTAssertTrue(settle { historyKeepers(in: host).count == 2 && historyKeepers(in: host).allSatisfy(\.hasRestored) },
                      "both scroll keepers attach before simulating the user's scroll")

        var (list, detail) = historyScrollViews(in: host)
        scroll(try XCTUnwrap(list), to: 400)
        scroll(try XCTUnwrap(detail), to: 260)
        pause()
        XCTAssertEqual(try XCTUnwrap(list).contentView.bounds.origin.y, 400, accuracy: 1)
        for keeper in historyKeepers(in: host) {
            let expected: CGFloat = keeper.key == .list ? 400 : 260
            XCTAssertEqual(try XCTUnwrap(keeper.memory.offset(for: keeper.key)), expected, accuracy: 1,
                           "the user scroll is recorded before leaving History")
        }

        // Away to General (the History subtree unmounts) and back.
        let table = try XCTUnwrap(firstTable(in: host))
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))
        table.selectRowIndexes([general], byExtendingSelection: false)
        pause()
        XCTAssertNil(historyScrollViews(in: host).list, "History really left the hierarchy")
        table.selectRowIndexes([history], byExtendingSelection: false)
        // Exercise the opposite ordering without waiting for keeper attachment or restoration.
        if releaseReloadImmediately { reload.release() }

        XCTAssertTrue(settle { historyScrollViews(in: host).list != nil && historyScrollViews(in: host).detail != nil })
        print("History rebuilt before reload wait: \(scrollDiagnostics(in: host))")
        XCTAssertTrue(settle { reload.started }, "re-entry starts its asynchronous archive reload")
        if !releaseReloadImmediately {
            // Force the reload to finish AFTER the rebuilt keepers restore. The old fixed delay could
            // inspect either side of this layout boundary, depending on the runner's scheduling.
            XCTAssertTrue(settle { historyKeepers(in: host).count == 2 && historyKeepers(in: host).allSatisfy(\.hasRestored) })
            reload.release()
        }
        XCTAssertTrue(settle {
            host.layoutSubtreeIfNeeded()
            let keepers = historyKeepers(in: host)
            let scrolls = historyScrollViews(in: host)
            return reload.returned && keepers.count == 2 && keepers.allSatisfy(\.hasRestored)
                && abs((scrolls.list?.contentView.bounds.origin.y ?? -1) - 400) <= 2
                && abs((scrolls.detail?.contentView.bounds.origin.y ?? -1) - 260) <= 2
        }, "re-entry layout and both restores finish: \(scrollDiagnostics(in: host))")
        print("History restored: \(scrollDiagnostics(in: host))")
        pause() // allow a subsequent lazy layout to invalidate an unstable restore
        (list, detail) = historyScrollViews(in: host)
        XCTAssertEqual(try XCTUnwrap(list).contentView.bounds.origin.y, 400, accuracy: 2,
                       "the list returns where it was left, not at the selected (newest) row")
        XCTAssertEqual(try XCTUnwrap(detail).contentView.bounds.origin.y, 260, accuracy: 2,
                       "the detail pane returns where it was left")
    }

    // MARK: - Helpers

    @MainActor private final class HistoryReloadGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var started = false
        private(set) var returned = false

        func wait() async {
            started = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }

        func returningPage() { returned = true }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func historyKeepers(in view: NSView) -> [SettingsHistoryScrollKeeper.KeeperView] {
        if let keeper = view as? SettingsHistoryScrollKeeper.KeeperView { return [keeper] }
        return view.subviews.flatMap(historyKeepers)
    }

    private func scrollDiagnostics(in host: NSView) -> String {
        historyKeepers(in: host).map { keeper in
            let scroll = keeper.enclosingScrollView
            return "\(keeper.key): restored=\(keeper.hasRestored), remembered=\(String(describing: keeper.memory.offset(for: keeper.key))), origin=\(scroll?.contentView.bounds.origin.y ?? -1), document=\(scroll?.documentView?.frame.height ?? -1), viewport=\(scroll?.contentView.bounds.height ?? -1)"
        }.joined(separator: "; ")
    }

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
    /// A rebuilt lazy document can expose its old estimate while it is still attaching. A live-scroll
    /// notification inside that attachment re-enters layout with an incomplete document (hosted: 464 pt).
    /// Force that ordering without depending on the OS's lazy-layout scheduling.
    func testRestoreWaitsUntilDocumentAttachmentFinishes() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        var attaching = true
        let token = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                                           object: view.scroll, queue: .main) { _ in
            MainActor.assumeIsolated {
                if attaching { self.resizeDocument(view.scroll, height: 464) }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        view.scroll.documentView?.addSubview(keeper)
        attaching = false
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 0, "no scroll while the document is attaching")
        clock.drain()
        XCTAssertEqual(view.scroll.documentView?.frame.height, 1800, "initial layout retained the complete extent")
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 400, accuracy: 0.5)
        XCTAssertEqual(memory.offset(for: .list), 400)
        _ = view.window
    }

    func testUserScrollBeforeFirstRestoreCancelsTheQueuedAttempt() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        view.scroll.documentView?.addSubview(makeKeeper(memory, clock))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view.scroll)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view.scroll)
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 120, accuracy: 0.5)
        XCTAssertEqual(memory.offset(for: .list), 120, "the user's position wins before the first scheduled restore")
        _ = view.window
    }

    func testDetachBeforeFirstRestoreInvalidatesTheQueuedAttempt() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        keeper.removeFromSuperview()
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(memory.offset(for: .list), 400)
        _ = view.window
    }

    func testPassiveDocumentClampDuringRestoreKeepsAndRestoresTheRememberedPosition() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        let token = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                                           object: view.scroll, queue: .main) { _ in
            MainActor.assumeIsolated {
                XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 400, accuracy: 0.5)
                self.resizeDocument(view.scroll, height: 500)
            }
        }
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 100, accuracy: 0.5, "AppKit really clamped the origin")
        XCTAssertEqual(memory.offset(for: .list), 400, "passive layout is not a user scroll")
        resizeDocument(view.scroll, height: 1800)
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 400, accuracy: 0.5)
        _ = view.window
    }

    func testPassiveViewportClampKeepsAndRestoresTheRememberedPosition() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        view.window.setContentSize(NSSize(width: 300, height: 1700))
        view.scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 100, accuracy: 0.5, "the larger viewport clamped the origin")
        XCTAssertEqual(memory.offset(for: .list), 650)
        view.window.setContentSize(NSSize(width: 300, height: 400))
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 650, accuracy: 0.5)
    }

    func testUserScrollAfterAPassiveClampCancelsTheRestore() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        resizeDocument(view.scroll, height: 900)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 500, accuracy: 0.5)
        userScroll(view.scroll, by: -200)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 300, accuracy: 0.5)
        resizeDocument(view.scroll, height: 1800)
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 300, accuracy: 0.5)
        XCTAssertEqual(memory.offset(for: .list), 300, "the user's new position wins")
        _ = view.window
    }

    func testAClampDuringLiveUserScrollingKeepsTheUsersNewPosition() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(400, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        view.scroll.documentView?.addSubview(makeKeeper(memory, clock))
        clock.step() // first restore runs after attachment
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view.scroll)
        resizeDocument(view.scroll, height: 500)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view.scroll)
        XCTAssertEqual(memory.offset(for: .list), 100)
        resizeDocument(view.scroll, height: 1800)
        clock.drain()
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 100, accuracy: 0.5)
        _ = view.window
    }

    func testRepeatedPassiveClampsDoNotRestartTheGiveUpBudget() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 1800)
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        resizeDocument(view.scroll, height: 900)
        for _ in 0..<15 { clock.step() }
        resizeDocument(view.scroll, height: 800)
        XCTAssertEqual(15 + clock.drain(), SettingsHistoryScrollKeeper.KeeperView.restoreAttempts)
        resizeDocument(view.scroll, height: 700)
        XCTAssertEqual(clock.pending, 0, "another clamp after give-up cannot restart the wait")
        resizeDocument(view.scroll, height: 1800)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 300, accuracy: 0.5, "no late jump after give-up")
        XCTAssertEqual(memory.offset(for: .list), 650)
        _ = view.window
    }

    private func resizeDocument(_ scroll: NSScrollView, height: CGFloat) {
        scroll.documentView?.setFrameSize(NSSize(width: 300, height: height))
        scroll.layoutSubtreeIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)
    }

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
        let clock = ManualRetryClock()
        let rebuilt = makeKeeper(memory, clock)
        second.scroll.documentView?.addSubview(rebuilt)
        clock.step() // first restore runs after attachment
        XCTAssertFalse(rebuilt.hasRestored, "waits for content tall enough to hold the position")
        XCTAssertEqual(memory.offset(for: .list), 650)
        clock.step(); clock.step() // two retries pass while the content is still short
        XCTAssertFalse(rebuilt.hasRestored)
        second.scroll.documentView?.setFrameSize(NSSize(width: 300, height: 2000))
        clock.step()
        XCTAssertTrue(rebuilt.hasRestored, "the next retry finds the content tall enough")
        XCTAssertEqual(second.scroll.contentView.bounds.origin.y, 650, accuracy: 0.5)
        _ = (first.window, second.window)
    }

    /// Round-2 review (ship-blocker): the user scrolls while the keeper is still waiting for content.
    /// Their position wins; growing content never yanks them back to the remembered offset.
    func testAUserScrollDuringTheWaitCancelsTheRestore() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 900) // 500 reachable: too short for 650
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        XCTAssertFalse(keeper.hasRestored, "waiting for content")
        userScroll(view.scroll, by: 200)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5, "the user's wheel scroll landed")
        view.scroll.documentView?.setFrameSize(NSSize(width: 300, height: 2000))
        clock.drain() // every queued retry runs against the now-tall content
        XCTAssertEqual(clock.pending, 0)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5, "no jump back to 650")
        XCTAssertEqual(memory.offset(for: .list), 200, "the user's position is what is remembered now")
        _ = view.window
    }

    /// FIXED-3: the window or split pane laying out during the wait changes only the clip view's size.
    /// That is not the user; the restore still lands and the remembered offset survives.
    func testASizeOnlyLayoutDuringTheWaitDoesNotCancelTheRestore() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 900) // 500 reachable: too short for 650
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        XCTAssertFalse(keeper.hasRestored, "waiting for content")
        // A layout pass resizes the visible area. AppKit posts no bounds notification for a frame-driven
        // resize, so the clip's bounds size is changed directly: that posts boundsDidChange with the origin
        // unchanged, which is the size-only notification at issue.
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                           object: view.scroll.contentView, queue: nil) { _ in posted += 1 }
        view.scroll.contentView.setBoundsSize(NSSize(width: 300, height: 360))
        NotificationCenter.default.removeObserver(token)
        XCTAssertGreaterThan(posted, 0, "a size-only bounds change really reached the keeper")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(memory.offset(for: .list), 650, "a size-only change never overwrites the remembered offset")
        view.scroll.documentView?.setFrameSize(NSSize(width: 300, height: 2000))
        clock.drain()
        XCTAssertTrue(keeper.hasRestored)
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 650, accuracy: 0.5, "the restore still lands")
        _ = view.window
    }

    /// Content never grows tall enough within the wait: the keeper gives up without a late jump.
    /// The wait is counted in retries on a manual clock and ends on the keeper's own give-up signal, so a
    /// loaded machine cannot starve it (it failed once at 1.64 s in a full M1 run on a wall-clock sleep).
    func testTimingOutLeavesThePositionWhereItWas() {
        let memory = SettingsHistoryScrollMemory()
        memory.record(650, for: .list)
        let view = scrollView(height: 600) // 200 reachable, and it stays that way
        let clock = ManualRetryClock()
        let keeper = makeKeeper(memory, clock)
        let gaveUp = expectation(description: "the keeper gave up")
        keeper.onGaveUp = { gaveUp.fulfill() }
        view.scroll.documentView?.addSubview(keeper)
        clock.step() // first restore runs after attachment
        XCTAssertFalse(keeper.hasRestored, "waiting for content")
        let retries = clock.drain()
        wait(for: [gaveUp], timeout: 1)
        XCTAssertEqual(retries, SettingsHistoryScrollKeeper.KeeperView.restoreAttempts, "it waits its full budget, then stops")
        XCTAssertEqual(clock.pending, 0, "nothing is left queued to jump later")
        XCTAssertTrue(keeper.hasRestored, "the wait ended")
        XCTAssertEqual(view.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "no late jump to the clamped offset")
        XCTAssertEqual(memory.offset(for: .list), 650, "giving up does not overwrite the remembered offset")
        _ = view.window
    }

    private func makeKeeper(_ memory: SettingsHistoryScrollMemory, _ clock: ManualRetryClock) -> SettingsHistoryScrollKeeper.KeeperView {
        let keeper = SettingsHistoryScrollKeeper.KeeperView(memory: memory, key: .list)
        keeper.scheduleRetry = { work in clock.schedule(work) }
        return keeper
    }

    /// Restore retries run only when the test steps them: no wall-clock time is involved.
    @MainActor private final class ManualRetryClock {
        private var queue: [@MainActor () -> Void] = []
        var pending: Int { queue.count }
        func schedule(_ work: @escaping @MainActor () -> Void) { queue.append(work) }
        func step() { if !queue.isEmpty { queue.removeFirst()() } }
        /// Runs queued retries, and any they queue, until none are left; returns how many ran.
        @discardableResult func drain(limit: Int = 1000) -> Int {
            var ran = 0
            while !queue.isEmpty, ran < limit { queue.removeFirst()(); ran += 1 }
            return ran
        }
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
