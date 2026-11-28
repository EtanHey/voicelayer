import AppKit
import QuartzCore
import SwiftUI

/// Candidate-6 QA (N19/N20): provide Dictations, Ask, and Speech history with horizontal category navigation. The
/// selector sits on top of the list, and a two-finger swipe or a sideways drag slides the lists with the finger.
///
/// - Motion (docs/tab-swipe.md): the selector's glass pill and the lists follow the fingers 1:1 and settle on one
///   critically damped spring (`GlassTabPager`), the same after a swipe, a click on a category or an arrow key, from
///   wherever they are drawn. Reduce Motion: nothing slides; the lists cross-fade by the same progress.
/// - A gesture picks its axis once (`NotchHistoryCategoryPager`), so a vertical scroll stays the list's own.
/// - The category reaches `archive.selectedScope` only when the motion comes to rest.
/// - The selector takes its height from the list; the drawer's height and pull are unchanged.
struct NotchHistoryCategoryPanel: View {
    /// The Dictations list as the notch builds it. Ask and Speech are the same list with their own rows.
    let dictations: NotchHistoryPanel
    @ObservedObject var archive: NotchHistoryArchiveStore

    var onOpenArchive: (SettingsHistoryDestination) -> Void = { _ in }

    /// The pill and the lists' position. Held, not observed: only the bar and the page wrappers redraw per frame.
    @State private var tabs: GlassTabPager
    @State private var gesture = NotchTabGesture()
    @State private var surface = NotchHistorySurfaceLease()
    @State private var selectorFocus = NotchHistorySelectorFocus()
    @State private var swipeCancellation = NotchTabSwipeFence()
    private let initialSwipe: CGFloat
    /// False while the panel is built but not shown (the Settings drawer keeps every tab's page laid out): it reads no
    /// archive and takes no gestures or keys.
    @Environment(\.notchHistorySurfacePresented) private var isPresented

    /// Each list's scroll indicator sits just outside its right edge, so neighbouring lists keep this gap.
    static let pageGap: CGFloat = 12
    private static let bottomFade: CGFloat = 12
    private static let scopes = SettingsHistoryScope.allCases

    /// `initialScope` and `initialSwipe` (points the lists are dragged, as mid-gesture) are for shots; `pager` lets a
    /// test drive the frames itself.
    init(dictations: NotchHistoryPanel, archive: NotchHistoryArchiveStore,
         initialScope: SettingsHistoryScope? = nil, initialSwipe: CGFloat = 0, pager: GlassTabPager? = nil,
         onOpenArchive: @escaping (SettingsHistoryDestination) -> Void = { _ in }) {
        self.dictations = dictations
        self.archive = archive
        self.onOpenArchive = onOpenArchive
        self.initialSwipe = initialSwipe
        let index = Self.scopes.firstIndex(of: initialScope ?? archive.selectedScope) ?? 0
        _tabs = State(initialValue: pager ?? GlassTabPager(count: Self.scopes.count, selection: index))
    }

    private var palette: VoiceBarNotchContrastPalette { dictations.palette }
    private var listHeight: CGFloat {
        max(0, dictations.listHeight - NotchHistoryPresentation.categorySelectorHeight
            - NotchHistoryPresentation.categorySelectorGap)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let stride = width + Self.pageGap
            VStack(spacing: NotchHistoryPresentation.categorySelectorGap) {
                selector(width: width)
                pages(width: width)
            }
            .background(NotchHistorySwipeMonitor(
                onBegin: { gesture.begin(at: CACurrentMediaTime()) },
                onMove: { dx, dy, time in gesture.move(dx: dx, dy: dy, stride: stride, pager: tabs, at: time) },
                onEnd: { time in gesture.release(pager: tabs, at: time) },
                onCancel: { time in gesture.cancel(pager: tabs, at: time) },
                onStep: { select(tabs.selection + $0) },
                cancellation: swipeCancellation, selectorFocus: selectorFocus, isActive: isPresented
            ))
            .background(GlassTabPagerClock(pager: tabs))
            .onAppear {
                if initialSwipe != 0 { tabs.present(Double(tabs.selection) - Double(initialSwipe / stride)) }
            }
        }
        .frame(height: dictations.listHeight)
        .onAppear {
            tabs.onSelect = { [archive] index in archive.selectedScope = Self.scopes[index] }
            // A click on a category, like an arrow key, ends the swipe in progress first.
            tabs.onPick = { [gesture, swipeCancellation] _ in
                gesture.interrupt(at: CACurrentMediaTime())
                swipeCancellation.generation &+= 1
            }
            surface.update(isPresented, archive)
        }
        .onChange(of: isPresented) { _, presented in surface.update(presented, archive) }
        .onChange(of: archive.selectedScope) { _, scope in
            tabs.follow(Self.scopes.firstIndex(of: scope) ?? 0)
        }
        .onDisappear { surface.update(false, archive) }
    }

    // MARK: Selector

    private func selector(width: CGFloat) -> some View {
        let tabs = Self.scopes.map { GlassTab(title: $0.title, spokenLabel: $0.title) }
        var metrics = GlassTabMetrics()
        metrics.fontSize = NotchHistoryPresentation.categorySelectorFontSize
        metrics.height = NotchHistoryPresentation.categorySelectorHeight
        metrics.fill = width
        metrics.inset = 0 // the pill fills its slot, as the old selection did
        let bar = NotchGlassTabBar(
            pager: self.tabs, tabs: tabs, accessibilityLabel: NotchHistoryPresentation.categorySelectorLabel,
            metrics: metrics, colors: .notch(palette),
            identifier: { NotchHistoryPresentation.categoryIdentifier(Self.scopes[$0]) },
            tooltip: { NotchHistoryPresentation.categoryTooltip(Self.scopes[$0]) }
        )
        return NotchHistorySelectorHost(content: AnyView(bar), focus: selectorFocus)
            .frame(width: width, height: NotchHistoryPresentation.categorySelectorHeight)
    }

    // MARK: Lists

    private func pages(width: CGFloat) -> some View {
        let stride = width + Self.pageGap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(Self.scopes.enumerated()), id: \.element) { index, scope in
                NotchTabPage(pager: tabs, index: index, stride: stride, content: list(scope).frame(width: width))
            }
        }
        .frame(width: width, height: listHeight, alignment: .topLeading)
        .padding(.horizontal, Self.pageGap / 2)
        .clipped()
        // The selector's height leaves a part row at the bottom: it fades out instead of being cut mid-letter.
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.bottomFade)
            }
        }
        .padding(.horizontal, -Self.pageGap / 2)
        .simultaneousGesture(
            DragGesture(minimumDistance: NotchHistoryCategoryPager.slop)
                .onChanged { value in
                    guard isPresented else { return }
                    gesture.drag(to: value.translation, stride: stride, pager: tabs, at: CACurrentMediaTime())
                }
                .onEnded { _ in gesture.release(pager: tabs, at: CACurrentMediaTime()) }
        )
    }

    private func list(_ scope: SettingsHistoryScope) -> NotchHistoryPanel {
        var panel = dictations
        panel.listHeight = listHeight
        panel.scope = scope
        // A click that ends a swipe is not a row click.
        panel.onCopy = { entry in
            guard !swipeJustHappened else { return false }
            return dictations.onCopy(entry)
        }
        panel.onRetranscribe = { path in if !swipeJustHappened { dictations.onRetranscribe(path) } }
        panel.onOpen = { entry in if !swipeJustHappened { dictations.onOpen(entry) } }
        panel.onPaste = { entry in if !swipeJustHappened { dictations.onPaste(entry) } }
        let rows: [NotchHistoryArchiveStore.Row]?
        switch scope {
        case .recording:
            panel.emptyState = NotchHistoryPresentation.emptyState(for: scope)
            return panel
        case .ask: rows = archive.ask
        case .speech: rows = archive.speech
        }
        panel.onOpenAtIndex = { index in
            guard !swipeJustHappened, let destination = rows?[safe: index]?.destination else { return }
            onOpenArchive(destination)
        }
        panel.rowHasActionableText = { rows?[safe: $0]?.hasActionableText ?? false }
        panel.entries = rows?.map(\.entry) ?? []
        panel.emptyState = NotchHistoryPresentation.emptyState(for: scope, isLoaded: rows != nil)
        panel.forcedHoverIndex = dictations.forcedHoverIndex
        panel.forcedScrollOffset = nil
        panel.rowHeader = { index in
            guard let row = rows?[safe: index] else { return nil }
            return [VoiceBarRelativeTime.label(row.entry.createdAt), row.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return panel
    }

    // MARK: Gesture state

    private var swipeJustHappened: Bool { gesture.justSwiped(pager: tabs, at: CACurrentMediaTime()) }

    /// An arrow key: the same spring a click and a release use (`onPick` ends any swipe in progress).
    private func select(_ index: Int) {
        tabs.select(index, at: CACurrentMediaTime())
    }
}

/// Whether this History surface holds the archive open: it reads Ask and Speech only while it is shown.
@MainActor final class NotchHistorySurfaceLease {
    private var isOpen = false

    func update(_ presented: Bool, _ archive: NotchHistoryArchiveStore) {
        guard presented != isOpen else { return }
        isOpen = presented
        if presented { archive.surfaceOpened() } else { archive.surfaceClosed() }
    }
}

extension EnvironmentValues {
    /// False for a History panel built but not on screen (a Settings drawer tab other than Dictation).
    @Entry var notchHistorySurfacePresented = true
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Feeds a trackpad's two-finger scroll over the lists to the pager. SwiftUI's vertical ScrollView would take these
/// events whole, so a local monitor looks at each one first: until the gesture's axis is known, and for every
/// vertical gesture, the event goes on to the list untouched; once it is a sideways swipe the list never sees it
/// (nor its momentum). A plain mouse wheel has no gesture phases and is left alone.
///
/// Left and Right require the list's AppKit first-responder target or the selector's own hosting subtree
/// (including Tab-focused SwiftUI buttons). Outside focus never leaks arrows from Settings or text editors. SwiftUI `.focusable()` is
/// deliberately avoided: it aborted the old hosted panel on close.
struct NotchHistorySwipeMonitor: NSViewRepresentable {
    let onBegin: () -> Void
    /// A step's deltas and its event time (seconds, the `CACurrentMediaTime` clock).
    let onMove: (CGFloat, CGFloat, Double) -> Bool
    let onEnd: (Double) -> Void
    let onCancel: (Double) -> Void
    /// -1 for Left, +1 for Right.
    let onStep: (Int) -> Void
    /// A reference fence: a selector/key change invalidates pending events immediately, before view updates.
    var cancellation: NotchTabSwipeFence? = nil
    var selectorFocus: NotchHistorySelectorFocus? = nil
    /// False while its History panel is built but not shown: it takes no swipes, keys or focus.
    var isActive = true
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.handlers = self
        view.canInteract = isActive && isEnabled
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.removeMonitor()
    }

    final class Probe: NSView {
        var handlers: NotchHistorySwipeMonitor?
        var canInteract = false {
            didSet {
                guard oldValue, !canInteract else { return }
                resetTracking()
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            }
        }
        private var monitor: Any?
        private var isTracking = false
        private var isSideways = false
        private var swallowsMomentum = false
        private var trackingGeneration = 0

        override var acceptsFirstResponder: Bool { canInteract }
        override func becomeFirstResponder() -> Bool { canInteract && super.becomeFirstResponder() }
        // Focus ownership must not make the nonactivating notch steal the key window on a pointer press.
        override var needsPanelToBecomeKey: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseDown {
                    self.handlePointer(event)
                    return event
                }
                return (event.type == .keyDown ? self.handleKey(event) : self.handle(event)) ? nil : event
            }
        }

        func removeMonitor() {
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resetTracking()
        }

        private func resetTracking() {
            isTracking = false
            isSideways = false
            swallowsMomentum = false
            trackingGeneration = handlers?.cancellation?.generation ?? 0
        }

        /// A pointer press focuses only this History region, including its category selector.
        func handlePointer(_ event: NSEvent) {
            guard let window, event.window === window, canInteract else { return }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
                if window.firstResponder === self { window.makeFirstResponder(nil) }
                return
            }
            // A future editor inside History must keep its native text navigation too.
            var hit = window.contentView.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
            while let view = hit {
                if view is NSTextField || view is NSTextView { return }
                hit = view.superview
            }
            window.makeFirstResponder(self)
        }

        /// Plain Left/Right belong to the categories only when their list/selector has focus in this key window.
        func handleKey(_ event: NSEvent) -> Bool {
            routeKey(event, isKeyWindow: window?.isKeyWindow ?? false)
        }

        /// `handleKey` with the key-window fact spelled out (an offscreen test panel cannot become key).
        func routeKey(_ event: NSEvent, isKeyWindow: Bool) -> Bool {
            guard let window, event.window === window, isKeyWindow, canInteract,
                  window.firstResponder === self || handlers?.selectorFocus?.owns(window.firstResponder) == true,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let handlers else { return false }
            switch event.keyCode {
            case 123: handlers.onStep(-1)
            case 124: handlers.onStep(1)
            default: return false
            }
            return true
        }

        /// An event's own time; a synthesized event can carry none, and the clock's own is the same timebase.
        static func time(of event: NSEvent) -> Double { event.timestamp > 0 ? event.timestamp : CACurrentMediaTime() }

        /// Whether the event belongs to a sideways swipe and must not reach the list.
        func handle(_ event: NSEvent) -> Bool {
            route(event, in: event.window, at: event.locationInWindow)
        }

        /// `handle` with the event's window and place spelled out (a test's synthetic scroll event carries neither).
        func route(_ event: NSEvent, in eventWindow: NSWindow?, at location: NSPoint) -> Bool {
            guard let window, eventWindow === window, canInteract, let handlers else { return false }
            if trackingGeneration != (handlers.cancellation?.generation ?? 0) { resetTracking() }
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
                isTracking = bounds.contains(convert(location, from: nil))
                if isTracking { handlers.onBegin() }
            }
            guard isTracking else { return false }
            if phase.contains(.ended) || phase.contains(.cancelled) {
                isTracking = false
                swallowsMomentum = isSideways
                let time = Self.time(of: event)
                if phase.contains(.cancelled) {
                    handlers.onCancel(time)
                } else {
                    handlers.onEnd(time)
                }
                return false // the list's scroll view sees its gesture end
            }
            guard phase.contains(.began) || phase.contains(.changed) else { return false }
            isSideways = handlers.onMove(event.scrollingDeltaX, event.scrollingDeltaY, Self.time(of: event))
            return isSideways
        }
    }
}
