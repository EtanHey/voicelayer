import AppKit
import SwiftUI

/// QA-06 (Etan, 2026-11-02: "the state is not kept between just traveling within the app"): where each
/// History scroll view was left. SettingsView owns one instance, so it outlives the History tab. It is a
/// plain class, not observable, so scrolling records positions without re-rendering Settings.
@MainActor
final class SettingsHistoryScrollMemory {
    enum Key: Hashable {
        case list
        /// The detail pane of one recording; only the most recent recording's position is kept.
        case detail(String)
    }

    private var offsets: [Key: CGFloat] = [:]

    func offset(for key: Key) -> CGFloat? { offsets[key] }

    func record(_ offset: CGFloat, for key: Key) {
        if case .detail = key { offsets = offsets.filter { if case .detail = $0.key { $0.key == key } else { true } } }
        offsets[key] = max(0, offset)
    }
}

/// Placed as the background of a scroll view's content. It records the enclosing NSScrollView's real
/// visible offset as the user scrolls, and puts the remembered offset back when the scroll view is rebuilt
/// (returning to History), independent of which row is selected.
struct SettingsHistoryScrollKeeper: NSViewRepresentable {
    let memory: SettingsHistoryScrollMemory
    let key: SettingsHistoryScrollMemory.Key

    func makeNSView(context: Context) -> KeeperView { KeeperView(memory: memory, key: key) }
    func updateNSView(_ view: KeeperView, context: Context) { view.key = key }

    final class KeeperView: NSView {
        let memory: SettingsHistoryScrollMemory
        var key: SettingsHistoryScrollMemory.Key
        private weak var clip: NSClipView?
        /// Nothing is recorded until the remembered offset has been put back, so the rebuilt view's
        /// starting position (the top) never overwrites where the user really was.
        private(set) var hasRestored = false
        /// Content arrives over a few layout passes; wait for it to be tall enough, for at most ~1 s.
        /// Giving up leaves the position alone: a late jump would land on whatever the user is reading.
        static let restoreAttempts = 30
        /// True only while the keeper itself moves the clip view, so its own bounds change and live-scroll
        /// notifications are never mistaken for the user.
        private var isApplying = false
        /// Bumped on cancel or detach; a queued retry from an older generation does nothing.
        private var restoreGeneration = 0
        /// The last clip origin seen. A bounds notification with the same origin is a size-only layout
        /// change (window or split pane resizing), never the user scrolling.
        private var lastOriginY: CGFloat?

        init(memory: SettingsHistoryScrollMemory, key: SettingsHistoryScrollMemory.Key) {
            self.memory = memory; self.key = key
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Leaving: stop listening before teardown can move the clip view and record a false position.
            if newWindow == nil { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scroll = enclosingScrollView, clip !== scroll.contentView else { return }
            detach()
            clip = scroll.contentView
            lastOriginY = scroll.contentView.bounds.origin.y
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(userBeganLiveScroll),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            restore(attempt: 0)
        }

        private func detach() {
            if let clip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
                NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification,
                                                          object: clip.superview)
            }
            clip = nil
            hasRestored = false
            restoreGeneration &+= 1
        }

        private func restore(attempt: Int) {
            guard !hasRestored, let clip, let scroll = clip.superview as? NSScrollView else { return }
            guard let target = memory.offset(for: key), target > 0 else { hasRestored = true; return }
            let reachable = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
            if attempt >= Self.restoreAttempts {
                hasRestored = true // Too short for too long: keep where it is, record from here on.
            } else if reachable >= target - 0.5 {
                // Bracketed like a user's live scroll: SwiftUI's hosting scroll view then adopts the offset
                // as its own. A bare clip-view move is undone by the next content update (the re-entry
                // reload put the list back at the top in the focused test).
                let center = NotificationCenter.default
                isApplying = true
                center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                scroll.reflectScrolledClipView(clip)
                center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                isApplying = false
                lastOriginY = clip.bounds.origin.y
                hasRestored = true
            } else {
                let generation = restoreGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, self.restoreGeneration == generation else { return }
                    self.restore(attempt: attempt + 1)
                }
            }
        }

        /// The user moved first (wheel, trackpad, scroller drag, Page Up/Down, arrows, Home/End all move
        /// the clip view): their position wins, and nothing queued may move it afterwards.
        private func userTookOver() {
            guard !hasRestored else { return }
            restoreGeneration &+= 1
            hasRestored = true
        }

        @objc private func userBeganLiveScroll() {
            guard !isApplying else { return }
            userTookOver()
        }

        @objc private func boundsChanged() {
            guard !isApplying, let clip else { return }
            let originY = clip.bounds.origin.y
            guard originY != lastOriginY else { return } // size-only: not the user
            lastOriginY = originY
            userTookOver()
            memory.record(clip.bounds.origin.y, for: key)
        }
    }
}
