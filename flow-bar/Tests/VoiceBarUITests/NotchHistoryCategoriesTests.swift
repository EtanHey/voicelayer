import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane H (N19, N20). Etan on candidate 6: "Still can't do side to side in the history of the settings nor in the
/// normal history… Can only see the transcriptions… history here should have had like ask and a speech history as
/// well."
///
/// The real BarView in the real panel, offscreen, with fixtures in all three categories. Two-finger swipes are real
/// phased scroll-wheel events sent through the app (nothing is posted to the system); what is on screen is read from
/// the accessibility tree, where only the category shown is exposed.
@MainActor
final class NotchHistoryCategoriesTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            // Offscreen SwiftUI builds its accessibility tree only for an AX client (NotchThresholdMotionTests' pattern).
            let app = NSApplication.shared
            let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
            guard app.responds(to: setter) else { return }
            let was = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let set = unsafeBitCast(app.method(for: setter), to: Setter.self)
            set(app, setter, true)
            restoreAccessibility = { set(app, setter, was) }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            restoreAccessibility?()
            restoreAccessibility = nil
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    // MARK: Axis and settle rules (pure)

    func testASidewaysGestureMovesOneCategoryAndAVerticalOneNever() {
        var pager = NotchHistoryCategoryPager(count: 3)
        pager.begin()
        XCTAssertFalse(pager.move(dx: -3, dy: 0), "inside the slop no axis is chosen")
        XCTAssertTrue(pager.move(dx: -60, dy: 4))
        XCTAssertEqual(pager.offset(width: 400), -63, "the lists follow the finger 1:1")
        XCTAssertEqual(pager.position(width: 400), 63.0 / 400, accuracy: 0.001, "and so does the selector thumb")
        pager.move(dx: -40, dy: 0)
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 1)

        pager.begin()
        XCTAssertFalse(pager.move(dx: 5, dy: -30), "a vertical gesture is the list's own scroll")
        XCTAssertFalse(pager.move(dx: 300, dy: -5), "and stays vertical however far it then wanders sideways")
        XCTAssertEqual(pager.offset(width: 400), 0)
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 1)

        pager.begin()
        XCTAssertFalse(pager.move(dx: -20, dy: 18), "a diagonal is not clearly sideways")
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 1)
    }

    func testAShortSwipeSpringsBackAFlickMovesOnAndTheEndsResist() {
        var pager = NotchHistoryCategoryPager(count: 3)
        pager.begin()
        pager.move(dx: -40, dy: 0)
        pager.move(dx: -2, dy: 0)
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 0, "42 pt of 400 is under the commit share and was not a flick")

        pager.begin()
        pager.move(dx: -20, dy: 0)
        pager.move(dx: -16, dy: 0)
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 1, "a flick moves on however short")

        pager.select(0)
        pager.begin()
        pager.move(dx: 200, dy: 0)
        XCTAssertEqual(pager.offset(width: 400), 200 * NotchHistoryCategoryPager.edgeResistance,
                       "before the first category the lists resist")
        pager.end(width: 400)
        XCTAssertEqual(pager.index, 0)
        pager.select(7)
        XCTAssertEqual(pager.index, 2, "an arrow key past the last category stays on it")
    }

    /// A History test that injects no loaders must never read this Mac's recordings.
    func testTheDefaultStoreNeverReadsTheRealArchiveInATestProcess() {
        XCTAssertFalse(NotchHistoryArchiveStore.readsRealArchive)
    }

    func testEveryCategoryHasAnEmptyStateWithoutDashes() {
        for scope in SettingsHistoryScope.allCases {
            let empty = NotchHistoryPresentation.emptyState(for: scope)
            XCTAssertFalse(empty.title.isEmpty)
            XCTAssertFalse(empty.detail.isEmpty)
            for text in [empty.title, empty.detail] {
                XCTAssertFalse(text.contains("—") || text.contains("--"), text)
            }
        }
    }

    // MARK: The real panel

    func testHistorySwipesBetweenDictationsAskAndSpeechAndReadsNothingWhileClosed() throws {
        let harness = makeHarness()
        XCTAssertEqual(harness.archive.readCount, 0, "a closed notch reads no archive")
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        drain(0.5)
        XCTAssertEqual(harness.archive.readCount, 0, "an archive change with History closed reads nothing")
        XCTAssertEqual(harness.loads.count, 0)

        open(harness, .openHistory)
        wait { harness.archive.ask != nil }
        XCTAssertEqual(harness.archive.readCount, 1, "opening History loads Ask and Speech once")
        for scope in SettingsHistoryScope.allCases {
            XCTAssertTrue(identifiers(harness).contains(NotchHistoryPresentation.categoryIdentifier(scope)),
                          "the selector shows \(scope.title)")
        }
        XCTAssertEqual(shown(harness), [.recording])

        XCTAssertEqual(try swipe(harness, dx: -160), 8, "the list never sees a sideways swipe's eight moves")
        XCTAssertEqual(shown(harness), [.ask], "a swipe left shows Ask")
        XCTAssertTrue(labels(harness).contains { $0.contains("Asked “Synthetic question 1?”") },
                      "an Ask row carries its question")
        try swipe(harness, dx: -160)
        XCTAssertEqual(shown(harness), [.speech], "and again shows Speech")
        try swipe(harness, dx: -160)
        XCTAssertEqual(shown(harness), [.speech], "Speech is the last category")

        // Vertical scrolling inside a category is the list's own, even when it drifts sideways.
        XCTAssertEqual(try swipe(harness, dx: 12, dy: -240), 0, "the list's scroll view gets every event of a vertical scroll")
        XCTAssertEqual(shown(harness), [.speech], "a vertical scroll never switches category")
        XCTAssertEqual(try swipe(harness, dx: 60, dy: -55), 0, "a diagonal one too")
        XCTAssertEqual(shown(harness), [.speech])
        // A plain mouse wheel (no gesture phases) is never the monitor's either.
        XCTAssertEqual(try swipe(harness, dx: 0, dy: -240, phased: false), 0)
        XCTAssertEqual(shown(harness), [.speech])

        try swipe(harness, dx: 160)
        XCTAssertEqual(shown(harness), [.ask], "a swipe right goes back")
        try swipe(harness, dx: 160)
        XCTAssertEqual(shown(harness), [.recording])
        XCTAssertEqual(harness.archive.readCount, 1, "swiping reads nothing more")

        harness.surface.send(.dismiss(.toggle))
        wait { !harness.model.isHistoryPanelOpen }
        drain(1.0)
        let closedReads = harness.archive.readCount
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        drain(0.5)
        XCTAssertEqual(harness.archive.readCount, closedReads, "once History closes, archive changes read nothing")
    }

    func testTheSettingsDrawerHistoryTabHasTheSameCategories() throws {
        let harness = makeHarness()
        open(harness, .openSettings(.history))
        wait { harness.archive.speech != nil }
        XCTAssertEqual(shown(harness), [.recording])
        try swipe(harness, dx: -160)
        XCTAssertEqual(shown(harness), [.ask], "the History tab swipes too")

        // The selector is a control too: a click on Speech goes straight there.
        let speech = try XCTUnwrap(frame(identified: NotchHistoryPresentation.categoryIdentifier(.speech), harness))
        let point = harness.panel.convertPoint(fromScreen: NSPoint(x: speech.midX, y: speech.midY))
        try send(.leftMouseDown, at: point, to: harness.panel)
        try send(.leftMouseUp, at: point, to: harness.panel)
        drain(0.5)
        XCTAssertEqual(shown(harness), [.speech])

        // Left and Right step a category while the notch panel is the key window.
        let monitor = try XCTUnwrap(swipeMonitor(harness.host))
        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: harness.panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code
            ))
        }
        XCTAssertTrue(harness.panel.makeFirstResponder(monitor))
        XCTAssertFalse(monitor.routeKey(try key(123), isKeyWindow: false),
                       "the arrows are not the notch's while another window has the keys")
        XCTAssertEqual(shown(harness), [.speech])
        XCTAssertTrue(monitor.routeKey(try key(123), isKeyWindow: true))
        drain(0.5)
        XCTAssertEqual(shown(harness), [.ask], "Left goes back one category")
        XCTAssertTrue(monitor.routeKey(try key(124), isKeyWindow: true))
        drain(0.5)
        XCTAssertEqual(shown(harness), [.speech], "Right goes forward")
        XCTAssertFalse(monitor.routeKey(try key(125), isKeyWindow: true), "Down stays the list's")
    }

    func testAnEmptyCategoryShowsItsEmptyRow() throws {
        let harness = makeHarness(askCount: 0)
        open(harness, .openHistory)
        wait { harness.archive.ask != nil }
        try swipe(harness, dx: -160)
        XCTAssertTrue(identifiers(harness).contains(NotchHistoryPresentation.emptyRowIdentifier))
        XCTAssertTrue(labels(harness).contains { $0.contains(NotchHistoryPresentation.emptyState(for: .ask).title) })
    }

    func testH2AskAndSpeechRowsOpenTheirOwnArchiveEntry() throws {
        for surface in [NotchSurfaceEvent.openHistory, .openSettings(.history)] {
            for scope in [SettingsHistoryScope.ask, .speech] {
                let harness = makeHarness()
                open(harness, surface)
                wait { harness.archive.speech != nil }
                try swipe(harness, dx: -160)
                if scope == .speech { try swipe(harness, dx: -160) }
                let row = try XCTUnwrap(frame(identified: "history-row-2", harness))
                let point = harness.panel.convertPoint(fromScreen: NSPoint(x: row.minX + 30, y: row.midY))
                try send(.leftMouseDown, at: point, to: harness.panel)
                try send(.leftMouseUp, at: point, to: harness.panel)
                drain(0.3)
                XCTAssertEqual(harness.opens.values, ["\(scope.rawValue):synthetic-\(scope.rawValue)-1"],
                               "a row must preserve its category and archive id")
            }
        }
    }

    func testH2SwipeReleaseCannotCopyButCopyWorksAfterCooldown() throws {
        var copies = 0
        let dictations = NotchHistoryPanel(
            entries: [RecentTranscriptionEntry(text: "Synthetic copy target.")], activeRetranscriptionPath: nil,
            palette: .resolve(for: .dark), onCopy: { _ in copies += 1; return true },
            onPaste: { _ in XCTFail("unexpected paste") }, onRetranscribe: { _ in }, forcedHoverIndex: 0)
        let archive = NotchHistoryArchiveStore(loadAsk: { _ in [] }, loadSpeech: { _ in [] })
        let host = NSHostingView(rootView: NotchHistoryCategoryPanel(dictations: dictations, archive: archive)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        host.frame = NSRect(x: 0, y: 0, width: 404, height: 276)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        windows.append(window)
        drain(0.2)
        host.layoutSubtreeIfNeeded()
        let copy = try XCTUnwrap(elements(host).first { $0.label == "Copy" && $0.frame.width > 0 }?.frame)
        let point = window.convertPoint(fromScreen: NSPoint(x: copy.midX, y: copy.midY))
        let monitor = try XCTUnwrap(swipeMonitor(host))
        let listPoint = monitor.convert(NSPoint(x: monitor.bounds.midX, y: monitor.bounds.midY), to: nil)
        for (phase, dx) in [(Int64(1), 0)] + Array(repeating: (Int64(2), -3), count: 8) + [(Int64(4), 0)] {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: 0, wheel2: Int32(dx), wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            _ = monitor.route(try XCTUnwrap(NSEvent(cgEvent: cg)), in: window, at: listPoint)
        }
        try send(.leftMouseDown, at: point, to: window)
        try send(.leftMouseUp, at: point, to: window)
        drain(0.02)
        XCTAssertEqual(copies, 0, "a click ending a swipe must not copy")
        drain(0.4)
        try send(.leftMouseDown, at: point, to: window)
        try send(.leftMouseUp, at: point, to: window)
        drain(0.02)
        XCTAssertEqual(copies, 1, "an intentional copy after the cooldown still works")
    }

    func testH2CategorySurvivesCloseReopenAcrossBothSurfaces() throws {
        let harness = makeHarness()
        open(harness, .openHistory)
        wait { harness.archive.speech != nil }
        try swipe(harness, dx: -160)
        try swipe(harness, dx: -160)
        XCTAssertEqual(shown(harness), [.speech])
        harness.surface.send(.dismiss(.toggle))
        drain(1.0)
        XCTAssertTrue(harness.archive.ask == nil, "closed History must release transcript rows")
        XCTAssertTrue(harness.archive.speech == nil)
        let reads = harness.archive.readCount
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        drain(0.3)
        XCTAssertEqual(harness.archive.readCount, reads, "closed History does not reload")
        open(harness, .openSettings(.history))
        wait { harness.archive.speech != nil }
        XCTAssertEqual(shown(harness), [.speech], "category memory survives changing the History surface")
        harness.surface.send(.openSettings(.general))
        drain(0.8)
        XCTAssertTrue(harness.archive.ask == nil)
        XCTAssertTrue(harness.archive.speech == nil)
        open(harness, .openSettings(.history))
        wait { harness.archive.speech != nil }
        XCTAssertEqual(shown(harness), [.speech])
        let nextSession = makeHarness()
        open(nextSession, .openHistory)
        XCTAssertEqual(shown(nextSession), [.recording], "a new session starts on Dictations")
    }

    func testH2ArchivesReleaseOnlyWhenTheLastSurfaceCloses() {
        let rows = [NotchHistoryArchiveStore.Row(entry: RecentTranscriptionEntry(text: "Synthetic archive row."), detail: nil)]
        let archive = NotchHistoryArchiveStore(loadAsk: { _ in rows }, loadSpeech: { _ in rows })
        archive.surfaceOpened()
        archive.surfaceOpened()
        wait { archive.speech != nil }
        XCTAssertEqual(archive.readCount, 1)
        archive.surfaceClosed()
        XCTAssertNotNil(archive.ask, "another History surface is still open")
        archive.surfaceClosed()
        XCTAssertTrue(archive.ask == nil)
        XCTAssertTrue(archive.speech == nil)
        NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange, object: nil)
        drain(0.3)
        XCTAssertEqual(archive.readCount, 1)
        archive.surfaceOpened()
        wait { archive.speech != nil }
        XCTAssertEqual(archive.readCount, 2, "reopening reloads instead of showing retained rows")
        archive.surfaceClosed()
    }

    private final class LoadLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<[NotchHistoryArchiveStore.Row], Never>] = []
        var count: Int { lock.withLock { pending.count } }
        func load() async -> [NotchHistoryArchiveStore.Row] {
            await withCheckedContinuation { continuation in lock.withLock { pending.append(continuation) } }
        }
        func release() {
            let continuations = lock.withLock { let all = pending; pending = []; return all }
            for continuation in continuations {
                continuation.resume(returning: [.init(entry: RecentTranscriptionEntry(text: "Synthetic late row."), detail: nil)])
            }
        }
    }

    func testH2CloseDuringLoadCannotRestoreClosedRows() {
        let latch = LoadLatch()
        let archive = NotchHistoryArchiveStore(loadAsk: { _ in await latch.load() }, loadSpeech: { _ in await latch.load() })
        archive.surfaceOpened()
        wait { latch.count == 2 }
        XCTAssertEqual(latch.count, 2)
        archive.surfaceClosed()
        latch.release()
        drain(0.1)
        XCTAssertTrue(archive.ask == nil)
        XCTAssertTrue(archive.speech == nil)
        archive.surfaceOpened()
        wait { latch.count == 2 }
        XCTAssertEqual(latch.count, 2)
        latch.release()
        wait { archive.speech != nil }
        XCTAssertNotNil(archive.ask)
        XCTAssertEqual(archive.readCount, 2)
        archive.surfaceClosed()
        XCTAssertTrue(archive.ask == nil)
        XCTAssertTrue(archive.speech == nil)
    }

    private final class OtherFocus: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testH2ArrowsRequireHistoryFocusNotMerelyTheKeyWindow() throws {
        let harness = makeHarness()
        open(harness, .openSettings(.history))
        let monitor = try XCTUnwrap(swipeMonitor(harness.host))
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: harness.panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        let other = OtherFocus(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        harness.host.addSubview(other)
        XCTAssertTrue(harness.panel.makeFirstResponder(other))
        XCTAssertFalse(monitor.routeKey(right, isKeyWindow: true), "arrows belong to the focused Settings control")
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        harness.host.addSubview(field)
        XCTAssertTrue(harness.panel.makeFirstResponder(field))
        XCTAssertFalse(monitor.routeKey(right, isKeyWindow: true), "arrows belong to the focused text field")
        XCTAssertTrue(harness.panel.makeFirstResponder(monitor), "the list has its own safe AppKit focus target")
        XCTAssertFalse(monitor.routeKey(right, isKeyWindow: false))
        XCTAssertTrue(monitor.routeKey(right, isKeyWindow: true), "a focused History list owns Right")
        drain(0.3)
        XCTAssertEqual(shown(harness), [.ask])
        // The same focus target covers a selector click, and a click on the Settings tab bar releases it.
        let selector = try XCTUnwrap(frame(identified: NotchHistoryPresentation.categoryIdentifier(.ask), harness))
        let selectorPoint = harness.panel.convertPoint(fromScreen: NSPoint(x: selector.midX, y: selector.midY))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: selectorPoint,
            modifierFlags: [], timestamp: 0, windowNumber: harness.panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(harness.panel.makeFirstResponder(other))
        monitor.handlePointer(click)
        XCTAssertTrue(harness.panel.firstResponder === monitor, "the category selector owns the History focus target")
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 1, y: harness.host.bounds.maxY - 1), modifierFlags: [], timestamp: 0,
            windowNumber: harness.panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        monitor.handlePointer(outside)
        XCTAssertFalse(monitor.routeKey(right, isKeyWindow: true), "outside controls release History focus")
        other.removeFromSuperview()
        field.removeFromSuperview()
    }

    func testH2AccessibilityUsesAskAndSpeechNounsOnBothSurfaces() throws {
        for surface in [NotchSurfaceEvent.openHistory, .openSettings(.history)] {
            let harness = makeHarness()
            open(harness, surface)
            wait { harness.archive.speech != nil }
            for scope in [SettingsHistoryScope.ask, .speech] {
                try swipe(harness, dx: -160)
                let row = try XCTUnwrap(tree(harness).first { $0.id == "history-row-1" })
                XCTAssertTrue(row.hint.localizedCaseInsensitiveContains(scope.rawValue), "hint identifies its category")
                XCTAssertFalse(row.hint.localizedCaseInsensitiveContains("recording"), "Ask/Speech must not claim to be recordings")
                XCTAssertTrue(row.label.hasPrefix(scope.title + ", "), "row label identifies its category")
            }
        }
    }

    func testH2LoadingStateDoesNotHaveBlankAccessibilityDetail() {
        XCTAssertTrue(NotchHistoryPresentation.emptyState(for: .ask, isLoaded: false).detail.isEmpty)
    }

    // MARK: Pictures (opt-in)

    /// Writes both History surfaces in each category, an empty category and one mid-swipe frame: the real History
    /// views at the notch's 420 pt, @2x. `VOICEBAR_H_SHOTS_DIR` is the folder, `VOICEBAR_H_SHOTS_PREFIX` the file
    /// prefix (before / after). The notch's glass material cannot render offscreen on the M1, so each picture
    /// says so and uses a solid backdrop.
    func testWriteHistoryCategoryShotsWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VOICEBAR_H_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_H_SHOTS_DIR to write the lane H History pictures")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = environment["VOICEBAR_H_SHOTS_PREFIX"] ?? "after"
        typealias Shot = (name: String, inSettings: Bool, scope: SettingsHistoryScope, swipe: CGFloat, asks: Int, light: Bool)
        var shots: [Shot] = []
        for (surface, inSettings) in [("history", false), ("settings-history", true)] {
            for scope in SettingsHistoryScope.allCases {
                shots.append(("\(surface)-\(scope.title.lowercased())", inSettings, scope, 0, 12, false))
            }
        }
        shots.append(("history-mid-swipe-dictations-to-ask", false, .recording, -110, 12, false))
        shots.append(("history-ask-empty", false, .ask, 0, 0, false))
        shots.append(("history-ask-light", false, .ask, 0, 12, true))
        for shot in shots {
            let fixture = makeFixture(askCount: shot.asks)
            let appearance: VoiceBarNotchAppearance = shot.light ? .light : .dark
            let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
            func list(height: CGFloat) -> AnyView {
                let dictations = NotchHistoryPanel(
                    entries: fixture.state.recentTranscriptionEntries, activeRetranscriptionPath: nil, palette: palette,
                    onCopy: { _ in true }, onPaste: { _ in }, onRetranscribe: { _ in }, listHeight: height, forcedHoverIndex: 0
                )
                return Self.historySurface(dictations, fixture.archive, shot.scope, shot.swipe)
            }
            let surface: AnyView
            let height: CGFloat
            if shot.inSettings {
                height = NotchSettingsDrawerPresentation.lowerSurfaceHeight
                surface = AnyView(VStack(spacing: 0) {
                    NotchSettingsDrawer(
                        selectedTab: .history, appearance: appearance, context: fixture.context,
                        history: {
                            AnyView(list(height: NotchSettingsDrawerPresentation.historyListHeight)
                                .padding(.top, NotchHistoryMorph.listTopInset))
                        },
                        onSelectTab: { _ in }
                    )
                    Color.clear.frame(height: NotchHistoryMorph.handleBandHeight)
                })
            } else {
                height = NotchHistoryMorph.lowerSurfaceHeight
                surface = AnyView(VStack(spacing: 0) {
                    list(height: NotchHistoryMorph.listHeight)
                        .padding(.horizontal, NotchHistoryMorph.listHorizontalInset)
                        .padding(.top, NotchHistoryMorph.listTopInset)
                    Color.clear.frame(height: NotchHistoryMorph.handleBandHeight)
                })
            }
            let size = CGSize(width: NotchHistoryMorph.bodyWidth, height: height + 30)
            let view = VStack(spacing: 0) {
                surface.frame(width: size.width, height: height, alignment: .top)
                Text("M1 offscreen render, synthetic rows. The notch glass cannot render here: solid backdrop.")
                    .font(.system(size: 9)).foregroundStyle(.gray).frame(height: 30)
            }
            .background(shot.light ? Color(white: 0.92) : Color(white: 0.1))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: shot.light ? .aqua : .darkAqua)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            drain(1.0)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(prefix)-\(shot.name).png"), options: .atomic)
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
    }

    /// The History list as the notch mounts it.
    private static func historySurface(
        _ dictations: NotchHistoryPanel, _ archive: NotchHistoryArchiveStore, _ scope: SettingsHistoryScope, _ swipe: CGFloat
    ) -> AnyView {
        AnyView(NotchHistoryCategoryPanel(dictations: dictations, archive: archive, initialScope: scope, initialSwipe: swipe))
    }

    // MARK: Harness

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private final class LoadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private final class OpenLog { var values: [String] = [] }

    private struct Harness {
        let model: VoiceBarNotchPresentationModel
        let surface: NotchSurfaceModel
        let host: PillHostingView<AnyView>
        let panel: FloatingPillPanel
        let archive: NotchHistoryArchiveStore
        let loads: LoadLog
        let opens: OpenLog
    }

    private static let marker: [SettingsHistoryScope: String] = [
        .recording: "Synthetic dictation", .ask: "Synthetic answer", .speech: "Synthetic speech",
    ]

    private struct Fixture {
        let state: VoiceState
        let archive: NotchHistoryArchiveStore
        let loads: LoadLog
        let context: NotchSettingsDrawerContext
    }

    /// Twenty dictations, `askCount` Ask exchanges and twenty Speech rows, all synthetic.
    private func makeFixture(askCount: Int) -> Fixture {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        func rows(_ scope: SettingsHistoryScope, _ count: Int, detail: (Int) -> String?) -> [NotchHistoryArchiveStore.Row] {
            (0 ..< count).map { index in
                NotchHistoryArchiveStore.Row(
                    entry: RecentTranscriptionEntry(
                        text: "\(Self.marker[scope]!) \(index + 1).", recordingPath: scope == .recording ? "/synthetic/\(index).wav" : nil,
                        createdAt: Date().addingTimeInterval(Double(-60 * (index + 1)))
                    ),
                    detail: detail(index),
                    destination: SettingsHistoryDestination(scope: scope, entryID: "synthetic-\(scope.rawValue)-\(index)")
                )
            }
        }
        state.recentTranscriptionEntries = rows(.recording, 20) { _ in nil }.map(\.entry)
        let asks = rows(.ask, askCount) { "Asked “Synthetic question \($0 + 1)?”" }
        let spoken = rows(.speech, 20) { _ in "0:13" }
        let loads = LoadLog()
        let archive = NotchHistoryArchiveStore(
            loadAsk: { _ in loads.add(); return asks }, loadSpeech: { _ in loads.add(); return spoken }
        )
        let context = NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in AnyView(Text("\(tab.title) pane")) })
        return Fixture(state: state, archive: archive, loads: loads, context: context)
    }

    private func makeHarness(askCount: Int = 12) -> Harness {
        let fixture = makeFixture(askCount: askCount)
        let (state, archive, loads, context) = (fixture.state, fixture.archive, fixture.loads, fixture.context)
        let opens = OpenLog()
        let model = VoiceBarNotchPresentationModel()
        let surface = NotchSurfaceModel()
        surface.log = { _ in }
        let host = PillHostingView(rootView: AnyView(BarView(
            state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: { opens.values.append("generic") },
            onOpenHistoryEntry: { opens.values.append("\($0.scope.rawValue):\($0.entryID)") },
            presentationModel: model, includesPanelOutsets: true, surface: surface, settingsDrawer: context
        ).historyCategories(archive: archive)))
        host.activeHitTestProvider = { _ in true }
        host.renderedSurfaceHitTestProvider = { _ in true }
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        model.setHovered(true)
        let harness = Harness(model: model, surface: surface, host: host, panel: panel, archive: archive, loads: loads, opens: opens)
        resize(harness)
        drain(0.3)
        return harness
    }

    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { drain() }
    }

    private func resize(_ harness: Harness) {
        let size = VoiceBarPanelLayout.make(
            presentation: harness.model.presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: harness.model.presentation).canvasGeometry
        ).panelSize
        harness.panel.setContentSize(size)
        harness.host.frame = NSRect(origin: .zero, size: size)
        harness.host.layoutSubtreeIfNeeded()
    }

    private func open(_ harness: Harness, _ event: NotchSurfaceEvent) {
        harness.surface.send(event)
        wait { harness.model.isHistoryPanelOpen }
        resize(harness)
        drain(1.0)
        resize(harness)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: NSWindow) throws {
        panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )))
    }

    /// Every accessibility element under the host, as (identifier, label, frame).
    private func elements(_ root: Any, depth: Int = 0) -> [(id: String, label: String, frame: NSRect, hint: String)] {
        guard depth < 40, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        // KVC on a key an element does not implement raises; ask first.
        func read(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var found = [(
            id: read("accessibilityIdentifier") as? String ?? "",
            label: read("accessibilityLabel") as? String ?? "",
            frame: (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero,
            hint: read("accessibilityHelp") as? String ?? ""
        )]
        for child in read("accessibilityChildren") as? [Any] ?? [] {
            found += elements(child, depth: depth + 1)
        }
        return found
    }

    private func tree(_ harness: Harness) -> [(id: String, label: String, frame: NSRect, hint: String)] {
        harness.host.layoutSubtreeIfNeeded()
        return elements(harness.host)
    }

    private func identifiers(_ harness: Harness) -> Set<String> { Set(tree(harness).map(\.id)) }
    private func labels(_ harness: Harness) -> [String] { tree(harness).map(\.label) }

    private func frame(identified id: String, _ harness: Harness) -> NSRect? {
        tree(harness).first { $0.id == id && $0.frame.width > 0 }?.frame
    }

    /// The categories whose rows are exposed: exactly the one on screen.
    private func shown(_ harness: Harness) -> Set<SettingsHistoryScope> {
        let all = labels(harness)
        return Set(SettingsHistoryScope.allCases.filter { scope in all.contains { $0.contains(Self.marker[scope]!) } })
    }

    /// A window point inside the list on screen (the middle of its second row, or of the empty row).
    private func listPoint(_ harness: Harness) -> NSPoint? {
        let rows = tree(harness).filter { $0.frame.width > 0 && ($0.id.hasPrefix("history-row-") || $0.id == NotchHistoryPresentation.emptyRowIdentifier) }
        guard let row = rows.first(where: { $0.id == "history-row-2" }) ?? rows.first else { return nil }
        return harness.panel.convertPoint(fromScreen: NSPoint(x: row.frame.midX, y: row.frame.midY))
    }

    /// The list on screen as AppKit's scroll view (SwiftUI's vertical ScrollView), found under a row.
    private func scrollView(_ harness: Harness, at point: NSPoint) -> NSScrollView? {
        func find(_ root: NSView) -> NSScrollView? {
            if let scroll = root as? NSScrollView, scroll.convert(scroll.bounds, to: nil).contains(point) { return scroll }
            for subview in root.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return find(harness.host)
    }

    private func swipeMonitor(_ root: NSView) -> NotchHistorySwipeMonitor.Probe? {
        if let probe = root as? NotchHistorySwipeMonitor.Probe, probe.window != nil { return probe }
        for subview in root.subviews {
            if let found = swipeMonitor(subview) { return found }
        }
        return nil
    }

    /// One two-finger trackpad gesture over the list: began, eight changes, ended. Real phased scroll-wheel events
    /// (nothing is posted to the system). A synthetic event has no window, so each goes to the category monitor's
    /// own routing with the panel named, and on to the list's scroll view exactly when the monitor lets it through,
    /// as AppKit would deliver it.
    /// Returns how many of its events the monitor kept from the list.
    @discardableResult
    private func swipe(_ harness: Harness, dx: CGFloat, dy: CGFloat = 0, phased: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let point = try XCTUnwrap(listPoint(harness), "a list is on screen", file: file, line: line)
        let monitor = try XCTUnwrap(swipeMonitor(harness.host), "the category swipe monitor is installed", file: file, line: line)
        let list = scrollView(harness, at: point)
        let steps = 8
        var events = [(dx: CGFloat, dy: CGFloat, phase: Int64)]()
        if phased { events.append((0, 0, 1)) } // began
        events += Array(repeating: (dx / CGFloat(steps), dy / CGFloat(steps), phased ? 2 : 0), count: steps) // changed
        if phased { events.append((0, 0, 4)) } // ended
        var kept = 0
        for step in events {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: phased ? 2 : 1,
                                           wheel1: Int32(step.dy), wheel2: Int32(step.dx), wheel3: 0))
            if phased {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
            }
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            if monitor.route(event, in: harness.panel, at: point) { kept += 1 } else { list?.scrollWheel(with: event) }
            drain(0.01)
        }
        drain(0.6)
        return kept
    }
}
