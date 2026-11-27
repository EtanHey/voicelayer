import AppKit
import SwiftUI

/// GO-1126 W1: a two-finger sideways swipe over the notch Settings drawer moves to the neighbouring tab, the way
/// BrainBar's pages swipe (`NDPagePager`, itself VoiceBar's History category rules). The gesture state is
/// `NotchHistoryCategoryPager`, unchanged:
///
/// - A gesture picks its axis once, from its first 6 pt: sideways only when it is 1.5 times more horizontal than
///   vertical. A vertical gesture stays the pane's own scroll for its whole length and never changes tab.
/// - It settles on release: past 0.22 of the drawer's width, or a flick (a last step of 14 pt or more in the same
///   direction), moves one tab; anything shorter moves none. One gesture moves at most one tab. The ends stop.
/// - The tab then changes through the same `onSelectTab` a tab click uses: the pane swaps with the drawer's own tab
///   crossfade, so the swipe has no slide of its own and Reduce Motion keeps working as before.
///
/// Precedence: the Dictation tab's list has its own sideways pager (Dictations / Ask / Narration), so there only a
/// gesture that begins over the tab bar swipes tabs. A gesture that begins over a text field or over something that
/// scrolls sideways itself belongs to that view for its whole length.
enum NotchSettingsTabSwipe {
    /// The tab `step` places from `tab` in on-screen order, clamped at the ends (no wrap).
    static func tab(from tab: SettingsTab, step: Int) -> SettingsTab {
        let tabs = SettingsTab.allCases
        let index = tabs.firstIndex(of: tab) ?? 0
        return tabs[min(tabs.count - 1, max(0, index + step))]
    }

    /// Whether a gesture beginning `y` points below the drawer's top edge swipes tabs on `tab`.
    static func swipesTabs(on tab: SettingsTab, fromTop y: CGFloat) -> Bool {
        guard tab == .history else { return true }
        return y <= NotchSettingsDrawerPresentation.topInset + NotchSettingsDrawerPresentation.tabBarHeight
    }

    /// The pager for a gesture that begins on `tab`.
    static func pager(on tab: SettingsTab) -> NotchHistoryCategoryPager {
        NotchHistoryCategoryPager(count: SettingsTab.allCases.count,
                                  index: SettingsTab.allCases.firstIndex(of: tab) ?? 0)
    }

    /// The tab a finished gesture settles on, or nil when it stays.
    static func settle(_ pager: inout NotchHistoryCategoryPager, from tab: SettingsTab, width: CGFloat,
                       flick: Bool? = nil) -> SettingsTab? {
        let before = pager.index
        pager.end(width: width, flick: flick)
        guard pager.index != before else { return nil }
        return SettingsTab.allCases[pager.index]
    }
}

/// Watches scroll-wheel events over the drawer for a tab swipe. Scroll events only: it never takes first responder,
/// so panes keep their own focus, keys and text editing.
struct NotchSettingsTabSwipeMonitor: NSViewRepresentable {
    /// Whether a gesture beginning this many points below the drawer's top swipes tabs.
    let tracks: (CGFloat) -> Bool
    let onBegin: () -> Void
    /// Returns whether the gesture is a tab swipe (the event is then kept from the pane).
    let onMove: (CGFloat, CGFloat) -> Bool
    /// The drawer's width, for the commit distance.
    let onEnd: (CGFloat) -> Void
    /// The system cancelled the gesture: forget it without settling, so no tab changes (Codex r1 on #976).
    let onCancel: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.handlers = self }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.removeMonitor() }

    final class Probe: NSView {
        var handlers: NotchSettingsTabSwipeMonitor?
        private var monitor: Any?
        private var isTracking = false
        private var isSideways = false
        private var swallowsMomentum = false

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return self.route(event, in: event.window, at: event.locationInWindow) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            isTracking = false
            isSideways = false
            swallowsMomentum = false
        }

        /// Whether the event belongs to a tab swipe and must not reach the pane. The window and place are spelled
        /// out so a test's synthetic scroll event can be routed.
        func route(_ event: NSEvent, in eventWindow: NSWindow?, at location: NSPoint) -> Bool {
            guard let window, eventWindow === window, let handlers else { return false }
            if !event.momentumPhase.isEmpty {
                let swallow = swallowsMomentum
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    swallowsMomentum = false
                }
                return swallow
            }
            let phase = event.phase
            if phase.contains(.began) {
                swallowsMomentum = false
                isSideways = false
                let point = convert(location, from: nil)
                isTracking = bounds.contains(point) && handlers.tracks(point.y)
                    && !Self.beginsOverOwnHorizontalScroller(in: window, at: location)
                if isTracking { handlers.onBegin() }
            }
            guard isTracking else { return false }
            if phase.contains(.cancelled) {
                isTracking = false
                swallowsMomentum = isSideways
                handlers.onCancel()
                return false
            }
            if phase.contains(.ended) {
                isTracking = false
                swallowsMomentum = isSideways
                handlers.onEnd(bounds.width)
                return false
            }
            guard phase.contains(.began) || phase.contains(.changed) else { return false }
            isSideways = handlers.onMove(event.scrollingDeltaX, event.scrollingDeltaY)
            return isSideways
        }

        /// A text field, or a scroll view whose content is wider than it, keeps its own sideways scrolling.
        static func beginsOverOwnHorizontalScroller(in window: NSWindow, at location: NSPoint) -> Bool {
            guard let content = window.contentView else { return false }
            var view = content.hitTest(content.convert(location, from: nil))
            while let current = view {
                if current is NSTextView || current is NSTextField { return true }
                if let scroll = current as? NSScrollView, let document = scroll.documentView,
                   document.frame.width > scroll.contentView.bounds.width + 1 { return true }
                view = current.superview
            }
            return false
        }
    }
}
