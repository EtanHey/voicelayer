import QuartzCore
import SwiftUI

/// What the Settings drawer shows that the notch view cannot build on its own. The app (and the UIE2E host) supply
/// it; a BarView without one keeps the 2.3 behaviour (the gear opens the Settings window).
public struct NotchSettingsDrawerContext {
    public var updates: NotchUpdateController?
    /// Reuse each Settings tab pane and its stores in the drawer (QA 0510 R2).
    /// The request may also identify a scroll destination, such as microphone priority (N9).
    public var pane: (SettingsTab, SettingsTabRequest?) -> AnyView

    public init(
        updates: NotchUpdateController?,
        pane: @escaping (SettingsTab, SettingsTabRequest?) -> AnyView = { _, _ in AnyView(EmptyView()) }
    ) {
        self.updates = updates
        self.pane = pane
    }
}

/// Copy and metrics for the drawer (unit-tested; no em dashes or double hyphens in anything user-visible).
public enum NotchSettingsDrawerPresentation {
    public static let tabBarHeight: CGFloat = 46
    public static let horizontalInset: CGFloat = 8
    /// The grouped Form's own side inset (macOS draws its cards this far inside the scroll view). The drawer cancels
    /// it so a section card's edges are the tab bar's edges.
    public static let groupedFormInset: CGFloat = 20
    /// Height of the fade at a pane's scrolling top edge (lane S PR 3: Etan's video showed a card's labels cut through
    /// under the tab bar while scrolling).
    public static let scrollEdgeFade: CGFloat = 20
    /// A grouped card's row inset; the version row uses it on both sides so its text and button line up with the
    /// rows above it.
    public static let rowLeadingPadding: CGFloat = 10
    public static let rowTrailingPadding: CGFloat = 10
    public static let titleFontSize: CGFloat = 13
    public static let detailFontSize: CGFloat = 11.5
    public static let tabGlyphSize: CGFloat = 13

    /// The height, in History row units, a drawer opens at before its grip has resized it: expanded History's
    /// eight. C6 L2c (N16): the grip drags it taller, up to `maximumRows`, and it reopens at the height it was left
    /// at (`NotchSettingsDrawerHeight.swift`). The window never resizes for any of these heights.
    public static let rows = NotchHistoryMorph.maximumRows

    /// The default drawer's height below the 32 pt band.
    public static var lowerSurfaceHeight: CGFloat {
        NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(rows))
    }

    public static let topInset: CGFloat = 6

    /// The default drawer's History tab list: below its tab bar, above the grip's band (BarView adds the grip).
    public static var historyListHeight: CGFloat {
        historyListHeight(rows: CGFloat(rows))
    }

    public static let versionTitle = "VoiceBar"
    public static let checkForUpdates = "Check for updates"
    public static let releaseNotes = "Release notes"

    public static func updateButtonTitle(_ version: String) -> String { "Update to \(version)" }

    public static func updateStatus(_ phase: NotchUpdatePhase) -> String? {
        switch phase {
        case .idle: nil
        case .checking: "Checking for updates…"
        case .upToDate: "No newer release is available."
        case let .ahead(latest): "No newer release. This build is past \(latest)."
        case let .available(version): "VoiceBar \(version) is available."
        case .couldNotCheck: "Could not check for updates. Try again in a moment."
        case .updating: "Updating. VoiceBar restarts when it is done."
        case let .refused(reason): reason
        }
    }

    /// A tab's tooltip. Never painted in the drawer (0510 N2: no explanatory prose rows).
    public static func tabDescription(_ tab: SettingsTab) -> String {
        switch tab {
        case .history: "Your recent dictations, asks and narrations."
        case .speech: "Narration voices, reading speed and the long-text threshold."
        case .dictionary: "Words VoiceBar should spell your way."
        case .transcription: "The local recognizer, its model and the processing options."
        case .general: "Permissions, the dictation key, your microphone and updates."
        }
    }
}

/// One notch glyph in its own colour, with no outline (owner r1). The drawer's icons once vanished (N3, N12) because
/// the panel's backing-scale pass asked SwiftUI's symbol image layers to redraw, which empties them; that is fixed
/// in `VoiceBarBackingScaleSynchronizer` and guarded by `NotchGlyphRepaintN12Tests`, not by how the glyph is drawn.
struct NotchGlyph: View {
    let systemName: String
    var pointSize: CGFloat = NotchSettingsDrawerPresentation.tabGlyphSize
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// 2.4 Lane A, Etan's QA 0510 N1: Settings as a notch drawer with the real settings in every tab. Pull History
/// further down, or press the gear, and it hangs from the notch with its tabs. Each tab is the Settings window's
/// own pane (it scrolls inside the drawer when it is taller); History is the notch's own History list.
///
/// Tabs move as the History categories do (docs/tab-swipe.md): the glass pill and the panes follow a two-finger swipe
/// 1:1 and settle on one spring after it, a click or an outside change of tab, from where they are drawn. Every pane
/// stays built and laid out side by side; the tab reaches `onSelectTab` only when the motion comes to rest. Reduce
/// Motion: the panes cross-fade in place.
struct NotchSettingsDrawer: View {
    let selectedTab: SettingsTab
    let appearance: VoiceBarNotchAppearance
    let context: NotchSettingsDrawerContext
    /// A spot the drawer was opened at (the microphone control opens General at Microphone priority).
    var request: SettingsTabRequest?
    /// The notch's History rows, for the History tab.
    var history: () -> AnyView = { AnyView(EmptyView()) }
    let onSelectTab: (SettingsTab) -> Void

    /// The pill and the panes' position. Held, not observed: only the bar and the page wrappers redraw per frame.
    @State private var tabs: GlassTabPager
    /// GO-1126 W1: the tab swipe in progress (`NotchSettingsTabSwipe`).
    @State private var gesture = NotchTabGesture()

    /// Room between neighbouring panes while they slide: a grouped Form is laid out `groupedFormInset` wider on each
    /// side, so this keeps one pane's overhang from ever showing over the next.
    static let pageGap: CGFloat = 2 * NotchSettingsDrawerPresentation.groupedFormInset

    init(selectedTab: SettingsTab, appearance: VoiceBarNotchAppearance, context: NotchSettingsDrawerContext,
         request: SettingsTabRequest? = nil, history: @escaping () -> AnyView = { AnyView(EmptyView()) },
         pager: GlassTabPager? = nil, onSelectTab: @escaping (SettingsTab) -> Void) {
        self.selectedTab = selectedTab
        self.appearance = appearance
        self.context = context
        self.request = request
        self.history = history
        self.onSelectTab = onSelectTab
        _tabs = State(initialValue: pager ?? GlassTabPager(count: SettingsTab.allCases.count,
                                                           selection: SettingsTab.allCases.firstIndex(of: selectedTab) ?? 0))
    }

    private var palette: VoiceBarNotchContrastPalette { .resolve(for: appearance) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let stride = width + Self.pageGap
            VStack(spacing: 0) {
                tabBar(width: width)
                // Always fills below the tabs, even for a pane that draws nothing, so the tabs never re-centre (N3).
                ZStack(alignment: .topLeading) {
                    ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
                        NotchTabPage(pager: tabs, index: index, stride: stride,
                                     content: content(tab).frame(width: width).frame(maxHeight: .infinity, alignment: .top))
                    }
                }
                .frame(width: width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
            }
            .background(NotchSettingsTabSwipeMonitor(
                // The monitor sits inside the drawer's top inset; the rule measures from the drawer's top edge.
                tracks: {
                    NotchSettingsTabSwipe.swipesTabs(on: selectedTab, fromTop: $0 + NotchSettingsDrawerPresentation.topInset)
                },
                onBegin: { gesture.begin(at: CACurrentMediaTime()) },
                onMove: { dx, dy, time in gesture.move(dx: dx, dy: dy, stride: stride, pager: tabs, at: time) },
                onEnd: { time in gesture.release(pager: tabs, at: time) },
                // Codex r1 on #976: a gesture the system cancels never changes tab.
                onCancel: { time in gesture.cancel(pager: tabs, at: time) }
            ))
            .background(GlassTabPagerClock(pager: tabs))
        }
        .padding(.horizontal, NotchSettingsDrawerPresentation.horizontalInset)
        .padding(.top, NotchSettingsDrawerPresentation.topInset)
        .onAppear {
            tabs.onSelect = { [onSelectTab] index in onSelectTab(SettingsTab.allCases[index]) }
            tabs.onPick = { [gesture] _ in gesture.interrupt(at: CACurrentMediaTime()) }
        }
        .onChange(of: selectedTab) { _, tab in
            tabs.onSelect = { [onSelectTab] index in onSelectTab(SettingsTab.allCases[index]) }
            tabs.follow(SettingsTab.allCases.firstIndex(of: tab) ?? 0)
        }
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .history:
            // Built with the other panes, but it reads the History archive only while its tab is the one shown.
            history()
                .environment(\.notchHistorySurfacePresented, selectedTab == .history)
        case .general:
            VStack(spacing: 0) {
                pane(.general)
                if let updates = context.updates {
                    NotchSettingsVersionRow(updates: updates, appearance: appearance)
                }
            }
        case .transcription, .dictionary, .speech:
            pane(tab)
        }
    }

    private func pane(_ tab: SettingsTab) -> some View {
        context.pane(tab, request?.tab == tab ? request : nil)
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            .environment(\.notchPaneInk, NotchPaneInk(appearance))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Tabs

    static func tabMetrics(width: CGFloat) -> GlassTabMetrics {
        var metrics = GlassTabMetrics()
        metrics.fontSize = 10
        metrics.symbolSize = NotchSettingsDrawerPresentation.tabGlyphSize
        metrics.symbolGap = 3
        metrics.height = NotchSettingsDrawerPresentation.tabBarHeight - 8
        metrics.fill = width
        return metrics
    }

    static var glassTabs: [GlassTab] {
        SettingsTab.allCases.map { GlassTab(title: $0.title, spokenLabel: $0.title, symbol: $0.systemImage) }
    }

    private func tabBar(width: CGFloat) -> some View {
        NotchGlassTabBar(
            pager: tabs, tabs: Self.glassTabs, accessibilityLabel: "Settings tabs",
            metrics: Self.tabMetrics(width: width), colors: .notch(palette),
            tooltip: { NotchSettingsDrawerPresentation.tabDescription(SettingsTab.allCases[$0]) }
        )
        .frame(width: width, height: NotchSettingsDrawerPresentation.tabBarHeight)
    }
}

/// A compact capsule button that reads on the notch glass in both appearances.
struct NotchDrawerButton: View {
    let title: String
    let palette: VoiceBarNotchContrastPalette
    var prominent = false
    var isEnabled = true
    /// An optional leading glyph (Dictionary's Add term). Without it the capsule is text only.
    var systemImage: String? = nil
    /// Ink for the label instead of the palette primary (Dictionary's Delete uses the palette's errorText).
    var ink: Color? = nil
    let action: () -> Void

    /// The capsule's fill, as an opacity of the palette primary.
    static func fillOpacity(prominent: Bool) -> Double { prominent ? 0.2 : 0.12 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
                .foregroundStyle((ink ?? palette.primary.color).opacity(isEnabled ? 1 : 0.45))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.primary.color.opacity(Self.fillOpacity(prominent: prominent)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(PillControlTooltip(text: title))
        .accessibilityLabel(title)
    }
}

/// The version row under General: "VoiceBar" with its action on the same line (Check for updates, or Release notes and
/// Update when a release is newer), then the full build line and the update status across the full width below
/// (never truncated; either wraps to a second line if it must). Etan (QA 2026-11-11): it read cramped when the status
/// was squeezed beside the button into two short lines; it now uses the card rows' 10 pt insets (lane S DESIGN.md §10).
struct NotchSettingsVersionRow: View {
    let updates: NotchUpdateController
    let appearance: VoiceBarNotchAppearance

    private var palette: VoiceBarNotchContrastPalette { .resolve(for: appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(NotchSettingsDrawerPresentation.versionTitle)
                    .font(.system(size: NotchSettingsDrawerPresentation.titleFontSize, weight: .medium))
                    .foregroundStyle(palette.primary.color)
                Spacer(minLength: 8)
                if let version = updates.availableVersion {
                    if let url = NotchUpdateController.releaseNotesURL(version: version) {
                        NotchDrawerButton(title: NotchSettingsDrawerPresentation.releaseNotes, palette: palette) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    NotchDrawerButton(title: NotchSettingsDrawerPresentation.updateButtonTitle(version),
                                      palette: palette, prominent: true, isEnabled: updates.canUpdate) {
                        updates.update()
                    }
                } else {
                    NotchDrawerButton(title: NotchSettingsDrawerPresentation.checkForUpdates, palette: palette,
                                      isEnabled: updates.phase != .checking && updates.phase != .updating) {
                        Task { await updates.checkForUpdates() }
                    }
                }
            }
            Text(updates.buildLine)
                .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                .monospacedDigit()
                // 2.4.6 track T: footer notes take the teleprompter's read-tier ink, like every note on the glass.
                .foregroundStyle(NotchPaneInk(appearance).note)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("notch-settings-build-line")
            if let status = NotchSettingsDrawerPresentation.updateStatus(updates.phase) {
                HStack(spacing: 6) {
                    if updates.phase == .checking || updates.phase == .updating {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    Text(status)
                        .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                        .foregroundStyle(NotchPaneInk(appearance).note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, NotchSettingsDrawerPresentation.rowLeadingPadding)
        .padding(.trailing, NotchSettingsDrawerPresentation.rowTrailingPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.primary.color.opacity(0.1)).frame(height: 0.5)
        }
        .task { if updates.status == nil { await updates.checkForUpdates(force: false) } }
    }
}

extension SettingsTab {
    /// The drawer panes that are grouped Forms (Dictionary scrolls its own list; History is the notch's rows).
    var notchUsesGroupedForm: Bool {
        switch self {
        case .general, .transcription, .speech: true
        case .dictionary, .history: false
        }
    }
}

/// Reported 2026-11-11: grouped Form margins compound the drawer inset.
/// Lay out the Form 20 pt wider on each side so cards meet the pane edges; the
/// edges; the drawer clips the pane, so the overlay scroller, which would sit in the clipped strip, is inset back to
/// just inside the visible edge.
struct NotchGroupedFormGutter: ViewModifier {
    let isGroupedForm: Bool

    func body(content: Content) -> some View {
        if isGroupedForm {
            content
                .padding(.horizontal, -NotchSettingsDrawerPresentation.groupedFormInset)
                .modifier(NotchScrollEdgeFade(isActive: true))
                .background(NotchFormScrollerInset(trailing: NotchSettingsDrawerPresentation.groupedFormInset - 1))
        } else {
            content
        }
    }
}

/// Finds the pane's scroll view (a sibling of this probe under the same hosting container) and insets its vertical
/// scroller. If AppKit's tree ever differs it finds nothing and changes nothing: the scroller is then clipped, never
/// misplaced.
struct NotchFormScrollerInset: NSViewRepresentable {
    let trailing: CGFloat

    func makeNSView(context: Context) -> Probe { Probe(trailing: trailing) }
    func updateNSView(_ view: Probe, context: Context) {
        view.trailing = trailing
        view.apply()
    }

    final class Probe: NSView {
        var trailing: CGFloat

        init(trailing: CGFloat) {
            self.trailing = trailing
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            guard let scrollView = Self.scrollView(near: self) else { return }
            let insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: trailing)
            if scrollView.scrollerInsets.right != insets.right { scrollView.scrollerInsets = insets }
        }

        /// The nearest NSScrollView among this probe's ancestors' descendants, searching outward three levels.
        static func scrollView(near view: NSView) -> NSScrollView? {
            var ancestor = view.superview
            for _ in 0 ..< 3 {
                guard let current = ancestor else { return nil }
                if let found = firstScrollView(in: current, skipping: view) { return found }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstScrollView(in root: NSView, skipping probe: NSView) -> NSScrollView? {
            for subview in root.subviews where subview !== probe {
                if let scroll = subview as? NSScrollView { return scroll }
                if let found = firstScrollView(in: subview, skipping: probe) { return found }
            }
            return nil
        }
    }
}

/// Fades a scrolling pane's top edge over `scrollEdgeFade` points, so content scrolled up under the tab bar (or the
/// Dictionary toolbar) dissolves instead of being cut through mid-line. At rest the first section header sits below
/// the fade.
struct NotchScrollEdgeFade: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.mask {
                VStack(spacing: 0) {
                    // Keep a clear guard below the tabs; a full-height fade leaves readable half-lines.
                    Color.clear.frame(height: NotchSettingsDrawerPresentation.scrollEdgeFade - 6)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                    Color.black
                }
            }
        } else {
            content
        }
    }
}

/// GO-1126 W1: centre the Dictionary rows. With a mouse attached macOS draws legacy scrollers, which take their
/// width out of the list, so the rows ended about 16 pt short of the toolbar's trailing edge and sat off-centre. The
/// drawer's list scroller overlays the rows instead (it appears while scrolling), so the rows span the same width as
/// the search and Add term row above them. Re-applied when the system scroller preference changes, because AppKit
/// resets every scroll view's style then.
struct NotchOverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        private var observer: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.apply() }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func apply() {
            guard let scrollView = NotchFormScrollerInset.Probe.scrollView(near: self) else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        }
    }
}
