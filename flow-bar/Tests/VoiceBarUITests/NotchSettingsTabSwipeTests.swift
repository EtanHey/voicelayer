import AppKit
import QuartzCore
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// GO-1126 W1: swiping sideways across the notch Settings tabs (Dictation · Narration · Dictionary · Transcription ·
/// General), with BrainBar's page-swipe rules.
@MainActor
final class NotchSettingsTabSwipeTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.contentView = nil; $0.close() }
        windows = []
        super.tearDown()
    }

    // MARK: Pure rules

    func testTabsAreInTheRuledOrder() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["Dictation", "Narration", "Dictionary", "Transcription", "General"])
    }

    func testStepClampsAtBothEnds() {
        XCTAssertEqual(NotchSettingsTabSwipe.tab(from: .history, step: -1), .history, "no wrap before Dictation")
        XCTAssertEqual(NotchSettingsTabSwipe.tab(from: .general, step: 1), .general, "no wrap past General")
        XCTAssertEqual(NotchSettingsTabSwipe.tab(from: .speech, step: 1), .dictionary)
        XCTAssertEqual(NotchSettingsTabSwipe.tab(from: .dictionary, step: -1), .speech)
    }

    /// A swipe of `steps` scroll steps at 120 Hz over pages `stride` apart, starting on `tab`: the tab it rests on.
    private func settle(from tab: SettingsTab, dx: CGFloat, dy: CGFloat = 0, steps: Int, pause: Double = 0,
                        cancel: Bool = false) -> SettingsTab {
        let pager = GlassTabPager(count: SettingsTab.allCases.count, selection: SettingsTab.allCases.firstIndex(of: tab)!)
        let gesture = NotchTabGesture()
        var time = 5.0
        gesture.begin(at: time)
        for _ in 0 ..< steps {
            time += 1.0 / 120
            _ = gesture.move(dx: dx, dy: dy, stride: 428, pager: pager, at: time)
        }
        if cancel { gesture.cancel(pager: pager, at: time) } else { gesture.release(pager: pager, at: time + pause) }
        return SettingsTab.allCases[pager.selection]
    }

    func testALongSidewaysSwipeMovesExactlyOneTab() {
        XCTAssertEqual(settle(from: .dictionary, dx: -10, steps: 40), .transcription,
                       "fingers moving left go to the next tab, one tab only")
        XCTAssertEqual(settle(from: .dictionary, dx: 10, steps: 40), .speech)
        XCTAssertEqual(settle(from: .speech, dx: -40, steps: 40), .dictionary, "a very long fast swipe still moves one")
    }

    func testAShortSlowSwipeStaysAndAFlickMoves() {
        XCTAssertEqual(settle(from: .speech, dx: -5, steps: 20, pause: 0.2), .speech,
                       "100 pt and a pause before lifting: back on the same tab")
        XCTAssertEqual(settle(from: .speech, dx: -16, steps: 5), .dictionary, "80 pt still moving at release: a flick")
    }

    func testAVerticalScrollNeverChangesTab() {
        var axis = NotchHistoryCategoryPager()
        XCTAssertNil(axis.move(dx: -1, dy: 8), "the axis is decided vertical in the first 6 pt")
        for _ in 0 ..< 40 { XCTAssertNil(axis.move(dx: -20, dy: 0), "a vertical gesture stays vertical") }
        XCTAssertEqual(settle(from: .general, dx: -1, dy: 8, steps: 40), .general)
    }

    func testTheEndsStop() {
        XCTAssertEqual(settle(from: .general, dx: -10, steps: 40), .general, "past General stays")
        XCTAssertEqual(settle(from: .history, dx: 10, steps: 40), .history, "before Dictation stays")
    }

    func testACancelSettlesBackOnTheTabItBeganOn() {
        XCTAssertEqual(settle(from: .dictionary, dx: -10, steps: 40, cancel: true), .dictionary)
    }

    func testDictationListKeepsItsOwnCategorySwipe() {
        let tabBarBottom = NotchSettingsDrawerPresentation.topInset + NotchSettingsDrawerPresentation.tabBarHeight
        XCTAssertTrue(NotchSettingsTabSwipe.swipesTabs(on: .history, fromTop: tabBarBottom - 4), "tab bar swipes tabs")
        XCTAssertFalse(NotchSettingsTabSwipe.swipesTabs(on: .history, fromTop: tabBarBottom + 40),
                       "over the Dictation list the Dictations / Ask / Narration pager owns the gesture")
        for tab in SettingsTab.allCases where tab != .history {
            XCTAssertTrue(NotchSettingsTabSwipe.swipesTabs(on: tab, fromTop: tabBarBottom + 120), "\(tab.title) pane")
        }
    }

    // MARK: Hosted drawer, real scroll events

    func testTwoFingerSwipeOverTheDrawerSelectsTheNeighbouringTab() throws {
        var selected: [SettingsTab] = []
        let (window, probe) = try host(tab: .dictionary) { selected.append($0) }
        let pane = NSPoint(x: probe.bounds.midX, y: probe.bounds.height - 60) // flipped: well below the tab bar
        XCTAssertTrue(try swipe(probe, in: window, from: pane, dx: -12, steps: 12), "a sideways swipe is kept from the pane")
        XCTAssertEqual(selected, [.transcription])
        selected = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        _ = try swipe(probe, in: window, from: pane, dx: 12, steps: 12)
        _ = try swipe(probe, in: window, from: pane, dx: 12, steps: 12)
        XCTAssertEqual(selected, [.dictionary, .speech], "and back, one tab per swipe")
    }

    /// Codex r1 on #976: a gesture the system cancels after travelling past the commit distance must not change tab.
    func testACancelledSwipePastTheThresholdKeepsTheTab() throws {
        var selected: [SettingsTab] = []
        let (window, probe) = try host(tab: .dictionary) { selected.append($0) }
        let pane = NSPoint(x: probe.bounds.midX, y: probe.bounds.height - 60)
        XCTAssertTrue(try swipe(probe, in: window, from: pane, dx: -12, steps: 12, finalPhase: 8),
                      "the cancelled gesture was a sideways swipe kept from the pane")
        XCTAssertEqual(selected, [], "a cancelled swipe never settles on a tab")
        _ = try swipe(probe, in: window, from: pane, dx: -12, steps: 12)
        XCTAssertEqual(selected, [.transcription], "the next swipe still works")
    }

    func testClickFencesTheOldSettingsSwipeUntilNextBegan() throws {
        let pager = GlassTabPager(count: SettingsTab.allCases.count, selection: 2)
        let (window, probe) = try host(tab: .dictionary, pager: pager) { _ in }
        let bar = NSPoint(x: probe.bounds.midX, y: 20)
        pager.isLive = { true }
        pager.onNeedsFrames = { _ in }

        _ = try route(1, probe, in: window, at: bar)
        XCTAssertTrue(try route(2, probe, in: window, at: bar, dx: -70))
        let metrics = NotchSettingsDrawer.tabMetrics(width: probe.bounds.width)
        let general = try XCTUnwrap(metrics.slotFrames(NotchSettingsDrawer.glassTabs).last)
        let tabBarHeight = NotchSettingsDrawerPresentation.tabBarHeight
        let point = probe.convert(NSPoint(x: general.midX, y: tabBarHeight / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: CACurrentMediaTime(),
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )))
        }
        let presented = pager.progress
        XCTAssertEqual(pager.phase, .settling)

        XCTAssertFalse(try route(2, probe, in: window, at: bar, dx: 180))
        XCTAssertFalse(try route(4, probe, in: window, at: bar))
        XCTAssertEqual(pager.progress, presented)
        XCTAssertEqual(pager.selection, 4)
        XCTAssertEqual(pager.phase, .settling)

        _ = try route(1, probe, in: window, at: bar)
        XCTAssertTrue(try route(2, probe, in: window, at: bar, dx: -20))
        XCTAssertEqual(pager.phase, .tracking)
        _ = try route(8, probe, in: window, at: bar)
    }

    func testCancelledSettingsSwipeThatGrabsASettlingClickReturnsToItsOwnStart() throws {
        let pager = GlassTabPager(count: SettingsTab.allCases.count)
        var selected: [SettingsTab] = []
        let (window, probe) = try host(tab: .history, pager: pager) { selected.append($0) }
        let bar = NSPoint(x: probe.bounds.midX, y: 20)
        pager.isLive = { true }
        pager.onNeedsFrames = { _ in }
        let time = CACurrentMediaTime() - 0.25
        pager.select(4, at: time)
        for step in 1 ... 30 { pager.tick(at: time + Double(step) / 120) }
        XCTAssertGreaterThan(pager.progress, 3.5)
        XCTAssertEqual(pager.phase, .settling)
        XCTAssertEqual(selected, [])

        _ = try route(1, probe, in: window, at: bar)
        XCTAssertTrue(try route(2, probe, in: window, at: bar, dx: 260))
        XCTAssertEqual(pager.phase, .tracking)
        XCTAssertLessThan(pager.progress, 3.5)
        _ = try route(8, probe, in: window, at: bar)
        XCTAssertEqual(pager.selection, 4, "cancel returns to the tab captured when the swipe grabbed the pager")
        let cancelTime = CACurrentMediaTime()
        for step in 1 ... 120 { pager.tick(at: cancelTime + Double(step) / 120) }
        XCTAssertEqual(pager.progress, 4)
        XCTAssertEqual(selected, [.general])
    }

    func testVerticalScrollOverTheDrawerReachesThePane() throws {
        var selected: [SettingsTab] = []
        let (window, probe) = try host(tab: .general) { selected.append($0) }
        let pane = NSPoint(x: probe.bounds.midX, y: probe.bounds.height - 60)
        XCTAssertFalse(try swipe(probe, in: window, from: pane, dx: 0, dy: -12, steps: 12),
                       "a vertical gesture is never kept from the pane")
        XCTAssertEqual(selected, [])
    }

    func testOnDictationOnlyTheTabBarSwipesTabs() throws {
        var selected: [SettingsTab] = []
        let (window, probe) = try host(tab: .history) { selected.append($0) }
        let list = NSPoint(x: probe.bounds.midX, y: probe.bounds.height - 60)
        XCTAssertFalse(try swipe(probe, in: window, from: list, dx: -12, steps: 12))
        XCTAssertEqual(selected, [], "the list's category pager owns this gesture")
        let tabBar = NSPoint(x: probe.bounds.midX, y: 20)
        _ = try swipe(probe, in: window, from: tabBar, dx: -12, steps: 12)
        XCTAssertEqual(selected, [.speech])
    }

    // MARK: Helpers

    /// The drawer with its tab held as the app holds it: a selection that comes to rest becomes the drawer's tab.
    private struct Host: View {
        @State var tab: SettingsTab
        let onSelect: (SettingsTab) -> Void
        let pager: GlassTabPager?

        init(initial: SettingsTab, pager: GlassTabPager?, onSelect: @escaping (SettingsTab) -> Void) {
            _tab = State(initialValue: initial)
            self.pager = pager
            self.onSelect = onSelect
        }

        var body: some View {
            NotchSettingsDrawer(
                selectedTab: tab, appearance: .dark,
                context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                    AnyView(Text("\(tab.title) pane").frame(maxWidth: .infinity, maxHeight: .infinity))
                }),
                history: { AnyView(Text("history rows").frame(maxWidth: .infinity, maxHeight: .infinity)) },
                pager: pager, onSelectTab: { tab = $0; onSelect($0) }
            )
        }
    }

    private func host(tab: SettingsTab, pager: GlassTabPager? = nil, onSelect: @escaping (SettingsTab) -> Void) throws
        -> (NSWindow, NotchSettingsTabSwipeMonitor.Probe) {
        let host = NSHostingView(rootView: Host(initial: tab, pager: pager, onSelect: onSelect).frame(width: 404, height: 360))
        host.frame = NSRect(x: 0, y: 0, width: 404, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        windows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let probe = try XCTUnwrap(Self.find(NotchSettingsTabSwipeMonitor.Probe.self, in: host))
        XCTAssertGreaterThan(probe.bounds.height, 300, "the probe covers the whole drawer, tab bar included")
        return (window, probe)
    }

    /// Began, `steps` changed events of `dx`/`dy`, ended. Returns whether any event was kept from the pane.
    /// `finalPhase` 4 ends the gesture, 8 is the system cancelling it.
    private func swipe(_ probe: NotchSettingsTabSwipeMonitor.Probe, in window: NSWindow, from point: NSPoint,
                       dx: Int32, dy: Int32 = 0, steps: Int, finalPhase: Int64 = 4) throws -> Bool {
        var kept = false
        let phases = [(Int64(1), Int32(0), Int32(0))] + Array(repeating: (Int64(2), dx, dy), count: steps)
            + [(finalPhase, Int32(0), Int32(0))]
        for (phase, x, y) in phases {
            if try route(phase, probe, in: window, at: point, dx: x, dy: y) { kept = true }
            // A trackpad reports about every 8 ms; the release reads the swipe's speed from these times.
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
        }
        return kept
    }

    private func route(_ phase: Int64, _ probe: NotchSettingsTabSwipeMonitor.Probe, in window: NSWindow,
                       at point: NSPoint, dx: Int32 = 0, dy: Int32 = 0) throws -> Bool {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: dy, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return probe.route(try XCTUnwrap(NSEvent(cgEvent: cg)), in: window, at: probe.convert(point, to: nil))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }
}
