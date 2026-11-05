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
        private enum RestorePhase { case waiting, restored, gaveUp }
        private var restorePhase: RestorePhase = .waiting
        var hasRestored: Bool { restorePhase != .waiting }
        /// Content arrives over a few layout passes; wait for it to be tall enough, for at most ~1 s.
        /// Giving up leaves the position alone: a late jump would land on whatever the user is reading.
        static let restoreAttempts = 30
        /// True only while the keeper itself moves the clip view, so its own bounds change and live-scroll
        /// notifications are never mistaken for the user.
        private var isApplying = false
        /// Bumped on cancel or detach; a queued retry from an older generation does nothing.
        private var restoreGeneration = 0
        /// Queues the next restore attempt. Production waits 30 ms on the main queue; tests inject a manual
        /// clock so the give-up is counted in attempts, never raced against wall-clock time under load.
        var scheduleRetry: (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { work() } }
        }
        /// Called once when the wait ends without content tall enough (the keeper gave up).
        var onGaveUp: (() -> Void)?
        /// The last clip origin seen. A bounds notification with the same origin is a size-only layout
        /// change (window or split pane resizing), never the user scrolling.
        private var lastOriginY: CGFloat?
        /// Reachable range at the last origin change; size-only notifications must not consume it
        /// before AppKit posts the resulting origin clamp.
        private var lastReachableY: CGFloat?
        private var isUserScrolling = false

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
            lastReachableY = reachableHeight(in: scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(userBeganLiveScroll),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(userEndedLiveScroll),
                                                   name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            restore(attempt: 0)
        }

        private func detach() {
            if let clip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
                NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification,
                                                          object: clip.superview)
                NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification,
                                                          object: clip.superview)
            }
            clip = nil
            restorePhase = .waiting
            isUserScrolling = false
            restoreGeneration &+= 1
        }

        private func restore(attempt: Int) {
            guard !hasRestored, let clip, let scroll = clip.superview as? NSScrollView else { return }
            guard let target = memory.offset(for: key), target > 0 else { restorePhase = .restored; return }
            let reachable = reachableHeight(in: scroll)
            if attempt >= Self.restoreAttempts {
                restorePhase = .gaveUp // Too short for too long: never restart this wait on layout alone.
                onGaveUp?()
                return
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
                lastReachableY = reachableHeight(in: scroll)
                if abs(clip.bounds.origin.y - target) <= 0.5 {
                    restorePhase = .restored
                    return
                }
            }
            let generation = restoreGeneration
            scheduleRetry { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.restore(attempt: attempt + 1)
            }
        }

        /// The user moved first (wheel, trackpad, scroller drag, Page Up/Down, arrows, Home/End all move
        /// the clip view): their position wins, and nothing queued may move it afterwards.
        private func userTookOver() {
            if !hasRestored { restoreGeneration &+= 1 }
            restorePhase = .restored
        }

        @objc private func userBeganLiveScroll() {
            guard !isApplying else { return }
            isUserScrolling = true
            userTookOver()
            if let clip { memory.record(clip.bounds.origin.y, for: key) }
        }

        @objc private func userEndedLiveScroll() {
            guard !isApplying else { return }
            isUserScrolling = false
        }

        private func reachableHeight(in scroll: NSScrollView) -> CGFloat {
            max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        }

        @objc private func boundsChanged() {
            guard !isApplying, let clip, let scroll = clip.superview as? NSScrollView else { return }
            let originY = clip.bounds.origin.y
            guard originY != lastOriginY else { return } // size-only: not the user
            let reachable = reachableHeight(in: scroll)
            let passiveClamp = !isUserScrolling && lastReachableY != reachable
                && (lastOriginY ?? 0) > reachable + 0.5 && abs(originY - reachable) <= 0.5
            lastOriginY = originY
            lastReachableY = reachable
            if passiveClamp {
                if restorePhase == .restored {
                    restorePhase = .waiting
                    restore(attempt: 0)
                }
                return
            }
            userTookOver()
            memory.record(clip.bounds.origin.y, for: key)
        }
    }
}
