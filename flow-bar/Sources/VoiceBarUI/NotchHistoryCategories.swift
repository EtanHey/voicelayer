import AppKit
import SwiftUI

/// Lane H (rows N19, N20; Etan, QA of candidate 6: "history here should have had like ask and a speech history as
/// well", "still can't do side to side"). The notch History as three categories: Dictations, Ask, Speech. A compact
/// selector sits on top of the list, and a two-finger swipe or a sideways drag slides the lists with the finger.
///
/// - Motion: the lists and the selector's thumb follow the finger 1:1, then settle on the drawer's own strong
///   ease-out (`NotchDrawerMotion`): the content timing after a swipe, the quicker tab timing after a click or an
///   arrow key. Only transforms move. Reduce Motion: nothing slides; the category crossfades when the gesture ends.
/// - A gesture picks its axis once (`NotchHistoryCategoryPager`), so a vertical scroll stays the list's own.
/// - The selector takes its height from the list; the drawer's height and pull are unchanged.
struct NotchHistoryCategoryPanel: View {
    /// The Dictations list as the notch builds it. Ask and Speech are the same list with their own rows.
    let dictations: NotchHistoryPanel
    @ObservedObject var archive: NotchHistoryArchiveStore

    var onOpenArchive: (SettingsHistoryDestination) -> Void = { _ in }

    @State private var pager: NotchHistoryCategoryPager
    @State private var selectorFocus = NotchHistorySelectorFocus()
    @State private var swipeCancellation = NotchHistorySwipeCancellation()
    @State private var swipeEndedAt: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each list's scroll indicator sits just outside its right edge, so neighbouring lists keep this gap.
    private static let pageGap: CGFloat = 12
    private static let bottomFade: CGFloat = 12
    private static let scopes = SettingsHistoryScope.allCases

    /// `initialScope` and `initialSwipe` (points the lists are dragged, as mid-gesture) are for shots.
    init(dictations: NotchHistoryPanel, archive: NotchHistoryArchiveStore,
         initialScope: SettingsHistoryScope? = nil, initialSwipe: CGFloat = 0,
         onOpenArchive: @escaping (SettingsHistoryDestination) -> Void = { _ in }) {
        self.dictations = dictations
        self.archive = archive
        self.onOpenArchive = onOpenArchive
        var pager = NotchHistoryCategoryPager(count: Self.scopes.count, index: Self.scopes.firstIndex(of: initialScope ?? archive.selectedScope) ?? 0)
        if initialSwipe != 0 { pager.move(dx: initialSwipe, dy: 0) }
        _pager = State(initialValue: pager)
    }

    private var palette: VoiceBarNotchContrastPalette { dictations.palette }
    private var listHeight: CGFloat {
        max(0, dictations.listHeight - NotchHistoryPresentation.categorySelectorHeight
            - NotchHistoryPresentation.categorySelectorGap)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: NotchHistoryPresentation.categorySelectorGap) {
                selector(width: width)
                pages(width: width)
            }
            .background(NotchHistorySwipeMonitor(
                onBegin: { beginSwipe() },
                onMove: { dx, dy in follow { $0.move(dx: dx, dy: dy) } },
                onEnd: { finish(width: width, flick: nil) },
                onStep: { select(pager.index + $0) },
                cancellation: swipeCancellation, selectorFocus: selectorFocus
            ))
        }
        .frame(height: dictations.listHeight)
        .onAppear { archive.surfaceOpened() }
        .onChange(of: archive.selectedScope) { _, scope in
            let index = Self.scopes.firstIndex(of: scope) ?? 0
            if index != pager.index { select(index) }
        }
        .onDisappear { archive.surfaceClosed() }
    }

    // MARK: Selector

    private func selector(width: CGFloat) -> some View {
        let segment = width / CGFloat(Self.scopes.count)
        let position = reduceMotion ? CGFloat(pager.index) : pager.position(width: width)
        let content = ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.primary.color.opacity(0.14))
                .frame(width: segment)
                .offset(x: position * segment)
            HStack(spacing: 0) {
                ForEach(Array(Self.scopes.enumerated()), id: \.element) { index, scope in
                    let isCurrent = Int(position.rounded()) == index
                    Button { select(index) } label: {
                        Text(scope.title)
                            .font(.system(size: NotchHistoryPresentation.categorySelectorFontSize,
                                          weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? palette.primary.color : palette.secondary.color)
                            .frame(width: segment, height: NotchHistoryPresentation.categorySelectorHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(PillControlTooltip(text: NotchHistoryPresentation.categoryTooltip(scope)))
                    .accessibilityIdentifier(NotchHistoryPresentation.categoryIdentifier(scope))
                    .accessibilityLabel(scope.title)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
        .frame(width: width, height: NotchHistoryPresentation.categorySelectorHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NotchHistoryPresentation.categorySelectorLabel)
        return NotchHistorySelectorHost(content: AnyView(content), focus: selectorFocus)
            .frame(width: width, height: NotchHistoryPresentation.categorySelectorHeight)
    }

    // MARK: Lists

    @ViewBuilder
    private func pages(width: CGFloat) -> some View {
        Group {
            if reduceMotion {
                NotchDrawerCrossfade(
                    key: pager.index,
                    animation: NotchDrawerMotion.easeOut(NotchDrawerMotion.tabInDuration),
                    transition: NotchDrawerMotion.tabTransition(reduceMotion: true)
                ) { index in
                    list(Self.scopes[index]).frame(width: width)
                }
            } else {
                HStack(spacing: Self.pageGap) {
                    ForEach(Array(Self.scopes.enumerated()), id: \.element) { index, scope in
                        list(scope)
                            .frame(width: width)
                            // Only the category on screen takes input or shows in the accessibility tree.
                            .allowsHitTesting(index == pager.index && !pager.isSwiping)
                            .accessibilityHidden(index != pager.index)
                    }
                }
                .frame(width: width, alignment: .leading)
                .offset(x: -CGFloat(pager.index) * (width + Self.pageGap) + pager.offset(width: width))
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
                    _ = follow { $0.move(to: value.translation) }
                }
                .onEnded { value in
                    let throwDistance = value.predictedEndTranslation.width - value.translation.width
                    finish(width: width, flick: abs(throwDistance) > 60 && (throwDistance > 0) == (value.translation.width > 0))
                }
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

    private var swipeJustHappened: Bool {
        pager.isSwiping || ProcessInfo.processInfo.systemUptime - swipeEndedAt < 0.35
    }

    /// The lists track the finger on the same frame: never animated. Only a sideways swipe gets that transaction;
    /// a vertical drag is the drawer's pull, whose own animations (the Settings hint) must not be switched off.
    private func follow(_ move: (inout NotchHistoryCategoryPager) -> Bool) -> Bool {
        var next = pager
        let isSideways = move(&next)
        guard isSideways else {
            pager = next
            return false
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { pager = next }
        return true
    }

    private func beginSwipe() {
        if pager.isSwiping { swipeEndedAt = ProcessInfo.processInfo.systemUptime }
        pager.begin()
    }

    private func finish(width: CGFloat, flick: Bool?) {
        if pager.isSwiping { swipeEndedAt = ProcessInfo.processInfo.systemUptime }
        settle(NotchDrawerMotion.contentInDuration) { $0.end(width: width, flick: flick) }
    }

    private func select(_ index: Int) {
        if pager.isSwiping { swipeEndedAt = ProcessInfo.processInfo.systemUptime }
        swipeCancellation.generation &+= 1
        settle(NotchDrawerMotion.tabInDuration) { $0.select(index) }
    }

    private func settle(_ duration: Double, _ change: (inout NotchHistoryCategoryPager) -> Void) {
        // Reduce Motion: no slide; `NotchDrawerCrossfade` fades the new category in by itself.
        if reduceMotion {
            change(&pager)
        } else {
            withAnimation(NotchDrawerMotion.easeOut(duration)) { change(&pager) }
        }
        archive.selectedScope = Self.scopes[pager.index]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class NotchHistorySwipeCancellation {
    var generation = 0
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
    let onMove: (CGFloat, CGFloat) -> Bool
    let onEnd: () -> Void
    /// -1 for Left, +1 for Right.
    let onStep: (Int) -> Void
    /// A reference fence: a selector/key change invalidates pending events immediately, before view updates.
    var cancellation: NotchHistorySwipeCancellation? = nil
    var selectorFocus: NotchHistorySelectorFocus? = nil

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.handlers = self
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.removeMonitor()
    }

    final class Probe: NSView {
        var handlers: NotchHistorySwipeMonitor?
        private var monitor: Any?
        private var isTracking = false
        private var isSideways = false
        private var swallowsMomentum = false
        private var trackingGeneration = 0

        override var acceptsFirstResponder: Bool { true }
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
            guard let window, event.window === window else { return }
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
            guard let window, event.window === window, isKeyWindow,
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

        /// Whether the event belongs to a sideways swipe and must not reach the list.
        func handle(_ event: NSEvent) -> Bool {
            route(event, in: event.window, at: event.locationInWindow)
        }

        /// `handle` with the event's window and place spelled out (a test's synthetic scroll event carries neither).
        func route(_ event: NSEvent, in eventWindow: NSWindow?, at location: NSPoint) -> Bool {
            guard let window, eventWindow === window, let handlers else { return false }
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
                handlers.onEnd()
                return false // the list's scroll view sees its gesture end
            }
            guard phase.contains(.began) || phase.contains(.changed) else { return false }
            isSideways = handlers.onMove(event.scrollingDeltaX, event.scrollingDeltaY)
            return isSideways
        }
    }
}
