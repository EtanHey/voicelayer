import AppKit
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

    func testALongSidewaysSwipeMovesExactlyOneTab() {
        var pager = NotchSettingsTabSwipe.pager(on: .dictionary)
        for _ in 0 ..< 40 { pager.move(dx: -10, dy: 0) } // 400 pt left: far past the 0.22 commit
        XCTAssertEqual(NotchSettingsTabSwipe.settle(&pager, from: .dictionary, width: 404), .transcription,
                       "fingers moving left go to the next tab, one tab only")
        var back = NotchSettingsTabSwipe.pager(on: .dictionary)
        for _ in 0 ..< 40 { back.move(dx: 10, dy: 0) }
        XCTAssertEqual(NotchSettingsTabSwipe.settle(&back, from: .dictionary, width: 404), .speech)
    }

    func testAShortSwipeStaysAndAFlickMoves() {
        var short = NotchSettingsTabSwipe.pager(on: .speech)
        for _ in 0 ..< 4 { short.move(dx: -5, dy: 0) } // 20 pt < 0.22 × 404, last step 5 pt: no flick
        XCTAssertNil(NotchSettingsTabSwipe.settle(&short, from: .speech, width: 404))
        var flick = NotchSettingsTabSwipe.pager(on: .speech)
        flick.move(dx: -6, dy: 0)
        flick.move(dx: -16, dy: 0)
        XCTAssertEqual(NotchSettingsTabSwipe.settle(&flick, from: .speech, width: 404), .dictionary)
    }

    func testAVerticalScrollNeverChangesTab() {
        var pager = NotchSettingsTabSwipe.pager(on: .general)
        XCTAssertFalse(pager.move(dx: -1, dy: 8), "the axis is decided vertical in the first 6 pt")
        for _ in 0 ..< 40 { XCTAssertFalse(pager.move(dx: -20, dy: 0), "a vertical gesture stays vertical") }
        XCTAssertNil(NotchSettingsTabSwipe.settle(&pager, from: .general, width: 404))
    }

    func testTheEndsStop() {
        var pager = NotchSettingsTabSwipe.pager(on: .general)
        for _ in 0 ..< 40 { pager.move(dx: -10, dy: 0) }
        XCTAssertNil(NotchSettingsTabSwipe.settle(&pager, from: .general, width: 404), "past General stays")
        var first = NotchSettingsTabSwipe.pager(on: .history)
        for _ in 0 ..< 40 { first.move(dx: 10, dy: 0) }
        XCTAssertNil(NotchSettingsTabSwipe.settle(&first, from: .history, width: 404), "before Dictation stays")
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
        _ = try swipe(probe, in: window, from: pane, dx: 12, steps: 12)
        XCTAssertEqual(selected, [.speech])
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

    private func host(tab: SettingsTab, onSelect: @escaping (SettingsTab) -> Void) throws
        -> (NSWindow, NotchSettingsTabSwipeMonitor.Probe) {
        let drawer = NotchSettingsDrawer(
            selectedTab: tab, appearance: .dark,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                AnyView(Text("\(tab.title) pane").frame(maxWidth: .infinity, maxHeight: .infinity))
            }),
            history: { AnyView(Text("history rows").frame(maxWidth: .infinity, maxHeight: .infinity)) },
            onSelectTab: onSelect
        )
        let host = NSHostingView(rootView: drawer.frame(width: 404, height: 360))
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
        let location = probe.convert(point, to: nil)
        var kept = false
        let phases = [(Int64(1), Int32(0), Int32(0))] + Array(repeating: (Int64(2), dx, dy), count: steps)
            + [(finalPhase, Int32(0), Int32(0))]
        for (phase, x, y) in phases {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: y, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if probe.route(try XCTUnwrap(NSEvent(cgEvent: cg)), in: window, at: location) { kept = true }
        }
        return kept
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }
}
