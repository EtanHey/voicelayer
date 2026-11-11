import SwiftUI

/// What the Settings drawer shows that the notch view cannot build on its own. The app (and the UIE2E host) supply
/// it; a BarView without one keeps the 2.3 behaviour (the gear opens the Settings window).
public struct NotchSettingsDrawerContext {
    public var updates: NotchUpdateController?
    /// The Settings window's own pane for a tab (`SettingsView.notchDrawerPane`), built from the same stores, so
    /// the drawer edits the real settings (Etan, QA 0510 R2: "we literally already have notch history, this is so
    /// easy to re-use"). The request carries a spot to scroll to (the microphone priority list, 0510 N9).
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
    public static let rowLeadingPadding: CGFloat = 10
    public static let rowTrailingPadding: CGFloat = 8
    public static let titleFontSize: CGFloat = 13
    public static let detailFontSize: CGFloat = 11.5
    public static let tabGlyphSize: CGFloat = 13

    /// The drawer's height in History row units: expanded History's eight, so the real settings panes get the most
    /// room the window (sized for eight) already has, and the History/Settings swap never resizes it.
    public static let rows = NotchHistoryMorph.maximumRows

    /// The drawer's height below the 32 pt band.
    public static var lowerSurfaceHeight: CGFloat {
        NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(rows))
    }

    public static let topInset: CGFloat = 6

    /// The History tab's list: the drawer below its tab bar, above the grip's band (BarView adds the grip).
    public static var historyListHeight: CGFloat {
        lowerSurfaceHeight - topInset - tabBarHeight - NotchHistoryMorph.listTopInset - NotchHistoryMorph.handleBandHeight
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
        case .general: "Permissions, the dictation key, your microphone and updates."
        case .transcription: "The local recognizer, its model and the processing options."
        case .dictionary: "Words VoiceBar should spell your way."
        case .speech: "Voices, reading speed and the long-text threshold."
        case .history: "Your recent dictations."
        }
    }
}

/// One notch glyph with the band's contrast edge (`notchAdaptiveGlyphEdge`). The edge is for legibility only. It
/// never kept a glyph painted: the drawer's icons vanished (N3, N12) because the panel's backing-scale pass asked
/// SwiftUI's symbol image layers to redraw, which empties them (`VoiceBarBackingScaleSynchronizer`, fixed there).
struct NotchGlyph: View {
    let systemName: String
    var pointSize: CGFloat = NotchSettingsDrawerPresentation.tabGlyphSize
    let color: Color
    let appearance: VoiceBarNotchAppearance

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(color)
            .notchAdaptiveGlyphEdge(VoiceBarNotchGlyphContrastTreatment.resolve(for: appearance).color)
    }
}

/// 2.4 Lane A, Etan's QA 0510 N1: Settings as a notch drawer with the real settings in every tab. Pull History
/// further down, or press the gear, and it hangs from the notch with its tabs. Each tab is the Settings window's
/// own pane (it scrolls inside the drawer when it is taller); History is the notch's own History list.
struct NotchSettingsDrawer: View {
    let selectedTab: SettingsTab
    let appearance: VoiceBarNotchAppearance
    let context: NotchSettingsDrawerContext
    /// A spot the drawer was opened at (the microphone control opens General at Microphone priority).
    var request: SettingsTabRequest?
    /// The notch's History rows, for the History tab.
    var history: () -> AnyView = { AnyView(EmptyView()) }
    let onSelectTab: (SettingsTab) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: VoiceBarNotchContrastPalette { .resolve(for: appearance) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            // Always fills below the tabs, even for a pane that draws nothing, so the tabs never re-centre (N3).
            // C6 L2 (S9): a tab switch crossfades its content (`NotchDrawerMotion.tabTransition`).
            Color.clear
                .overlay(alignment: .top) {
                    NotchDrawerCrossfade(
                        key: selectedTab,
                        animation: NotchDrawerMotion.easeOut(NotchDrawerMotion.tabInDuration),
                        transition: NotchDrawerMotion.tabTransition(reduceMotion: reduceMotion)
                    ) { tab in
                        content(tab)
                    }
                }
                .clipped()
        }
        .padding(.horizontal, NotchSettingsDrawerPresentation.horizontalInset)
        .padding(.top, NotchSettingsDrawerPresentation.topInset)
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .history:
            history()
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = tab == selectedTab
                let ink = isSelected ? palette.primary.color : palette.secondary.color
                Button { onSelectTab(tab) } label: {
                    VStack(spacing: 3) {
                        NotchGlyph(systemName: tab.systemImage, color: ink, appearance: appearance)
                        Text(tab.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchSettingsDrawerPresentation.tabBarHeight - 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.primary.color.opacity(isSelected ? 0.14 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(PillControlTooltip(text: NotchSettingsDrawerPresentation.tabDescription(tab)))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(height: NotchSettingsDrawerPresentation.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }
}

/// A compact capsule button that reads on the notch glass in both appearances.
struct NotchDrawerButton: View {
    let title: String
    let palette: VoiceBarNotchContrastPalette
    var prominent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(palette.primary.color.opacity(isEnabled ? 1 : 0.45))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.primary.color.opacity(prominent ? 0.2 : 0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(PillControlTooltip(text: title))
        .accessibilityLabel(title)
    }
}

/// The version row under General: the full build line (never truncated, wraps to a second line if it must), Check
/// for updates, and when a release is newer, its notes and an Update button.
struct NotchSettingsVersionRow: View {
    let updates: NotchUpdateController
    let appearance: VoiceBarNotchAppearance

    private var palette: VoiceBarNotchContrastPalette { .resolve(for: appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                NotchGlyph(systemName: "info.circle", color: palette.secondary.color, appearance: appearance)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NotchSettingsDrawerPresentation.versionTitle)
                        .font(.system(size: NotchSettingsDrawerPresentation.titleFontSize))
                        .foregroundStyle(palette.primary.color)
                    Text(updates.buildLine)
                        .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                        .monospacedDigit()
                        .foregroundStyle(palette.tertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("notch-settings-build-line")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 20)
                if updates.phase == .checking || updates.phase == .updating {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                }
                if let status = NotchSettingsDrawerPresentation.updateStatus(updates.phase) {
                    Text(status)
                        .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                        .foregroundStyle(palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }
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
        }
        .padding(.leading, NotchSettingsDrawerPresentation.rowLeadingPadding)
        .padding(.trailing, NotchSettingsDrawerPresentation.rowTrailingPadding)
        .padding(.vertical, 6)
        .task { if updates.status == nil { await updates.checkForUpdates(force: false) } }
    }
}
