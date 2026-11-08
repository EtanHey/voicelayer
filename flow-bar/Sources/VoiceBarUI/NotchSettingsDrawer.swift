import SwiftUI

/// What the Settings drawer reads and does that the notch view cannot know on its own. The app (and the UIE2E
/// host) supply it; a BarView without one keeps the 2.3 behaviour (the gear opens the Settings window).
public struct NotchSettingsDrawerContext {
    /// "Hold F5 to dictate", or the hint that says why the key is off.
    public var shortcutHint: () -> String
    /// The microphone-priority default (read-only here, as in the menus: D2).
    public var defaultMicrophoneName: () -> String?
    public var updates: NotchUpdateController?
    /// Opens the full Settings window at a tab (and a spot in it).
    public var openSettingsWindow: (SettingsTab, SettingsFocus?) -> Void

    public init(
        shortcutHint: @escaping () -> String,
        defaultMicrophoneName: @escaping () -> String?,
        updates: NotchUpdateController?,
        openSettingsWindow: @escaping (SettingsTab, SettingsFocus?) -> Void
    ) {
        self.shortcutHint = shortcutHint
        self.defaultMicrophoneName = defaultMicrophoneName
        self.updates = updates
        self.openSettingsWindow = openSettingsWindow
    }
}

/// Copy and metrics for the drawer (unit-tested; no em dashes or double hyphens in anything user-visible).
public enum NotchSettingsDrawerPresentation {
    public static let tabBarHeight: CGFloat = 46
    public static let rowHeight: CGFloat = 44
    public static let rowSpacing: CGFloat = 2
    public static let horizontalInset: CGFloat = 8
    public static let rowLeadingPadding: CGFloat = 10
    public static let rowTrailingPadding: CGFloat = 8
    public static let titleFontSize: CGFloat = 13
    public static let detailFontSize: CGFloat = 11.5
    /// The widest the microphone name may draw before it ends in "…" (one line, never wrapped).
    public static let microphoneNameWidthBudget: CGFloat = 210

    /// The drawer's height in History row units: between collapsed (6) and expanded (8) History, so the swap
    /// between them is a short spring on the same shell and the window (sized for 8) never resizes.
    public static let rows = 7

    /// The drawer's height below the 32 pt band (fits the General tab with no dead space).
    public static var lowerSurfaceHeight: CGFloat {
        NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(rows))
    }

    public static func permissionTitle(_ permission: HotkeyPermission) -> String {
        switch permission {
        case .microphone: "Microphone access is off"
        case .accessibility: "Accessibility is off"
        case .inputMonitoring: "Input Monitoring is off"
        }
    }

    public static func permissionDetail(_ permission: HotkeyPermission) -> String {
        switch permission {
        case .microphone: "VoiceBar cannot hear you until it is allowed."
        case .accessibility: "Needed to paste where you were typing."
        case .inputMonitoring: "Needed for the F5 key."
        }
    }

    /// One row for the broken steps, so three missing permissions never push the version row off the drawer.
    public static func permissionSummary(_ missing: [HotkeyPermission]) -> (title: String, detail: String) {
        guard missing.count > 1 else {
            let permission = missing.first ?? .microphone
            return (permissionTitle(permission), permissionDetail(permission))
        }
        let names = missing.map { permission -> String in
            switch permission {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }
        return ("\(missing.count) permissions are off", names.joined(separator: ", "))
    }

    public static let allSetTitle = "Permissions"
    public static let allSetDetail = "All set"
    public static let shortcutTitle = "Dictation key"
    public static let microphoneTitle = "Microphone"
    public static let versionTitle = "VoiceBar"
    public static let checkForUpdates = "Check for updates"
    public static let releaseNotes = "Release notes"
    public static let allSettings = "All settings…"

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

    public static func tabDescription(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: "Permissions, the dictation key, your microphone and updates."
        case .transcription: "The local recognizer, its model and the processing options."
        case .dictionary: "Words VoiceBar should spell your way."
        case .speech: "Voices, reading speed and the long-text threshold."
        case .history: "Every dictation, Ask and read-aloud, with playback."
        }
    }

    public static func openTabTitle(_ tab: SettingsTab) -> String { "Open \(tab.title) settings" }

    /// The mic name on ONE line within `budget`: whole when it fits, else cut at a word or character with "…".
    public static func microphoneLine(_ name: String?, budget: CGFloat = microphoneNameWidthBudget,
                                      measure: (String) -> CGFloat = NotchSettingsDrawerPresentation.measure) -> String {
        let full = MicrophoneDefaultPresentation.title(name.map(flattened))
        guard measure(full) > budget else { return full }
        var characters = Array(full)
        while !characters.isEmpty, measure(String(characters) + "…") > budget {
            characters.removeLast()
        }
        return String(characters).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func measure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: detailFontSize)]).width
    }
}

/// 2.4 Lane A: Settings as a notch drawer. Pull History further down, or press the gear, and it hangs from the
/// notch with its tabs. General is finished here; the other tabs lead to the Settings window at that tab.
struct NotchSettingsDrawer: View {
    let selectedTab: SettingsTab
    let palette: VoiceBarNotchContrastPalette
    let missingPermissions: [HotkeyPermission]
    let context: NotchSettingsDrawerContext
    let onSelectTab: (SettingsTab) -> Void
    /// Opens the Settings window (the drawer closes first; that is the row's job done).
    let onOpenWindow: (SettingsTab, SettingsFocus?) -> Void

    @State private var hoveredRow: String?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                if selectedTab == .general {
                    generalTab
                } else {
                    tabEntry(selectedTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, NotchSettingsDrawerPresentation.horizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = tab == selectedTab
                Button { onSelectTab(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(isSelected ? palette.primary.color : palette.secondary.color)
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

    // MARK: General

    private var generalTab: some View {
        VStack(spacing: NotchSettingsDrawerPresentation.rowSpacing) {
            if missingPermissions.isEmpty {
                row(id: "permissions", symbol: "checkmark.seal.fill",
                    title: NotchSettingsDrawerPresentation.allSetTitle,
                    detail: NotchSettingsDrawerPresentation.allSetDetail)
            } else {
                let summary = NotchSettingsDrawerPresentation.permissionSummary(missingPermissions)
                row(id: "permissions", symbol: "exclamationmark.triangle.fill", title: summary.title,
                    detail: summary.detail, tint: .orange) {
                    actionButton("Fix…") { onOpenWindow(.general, .permissions) }
                }
            }
            row(id: "shortcut", symbol: "keyboard", title: NotchSettingsDrawerPresentation.shortcutTitle,
                detail: context.shortcutHint())
            row(id: "microphone", symbol: "mic", title: NotchSettingsDrawerPresentation.microphoneTitle,
                detail: NotchSettingsDrawerPresentation.microphoneLine(context.defaultMicrophoneName()),
                tooltip: MicrophoneDefaultPresentation.title(context.defaultMicrophoneName())) {
                actionButton(MicrophoneDefaultPresentation.changeTitle) { onOpenWindow(.general, .microphonePriority) }
            }
            if let updates = context.updates {
                NotchSettingsVersionRow(updates: updates, palette: palette)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                actionButton(NotchSettingsDrawerPresentation.allSettings) { onOpenWindow(.general, nil) }
            }
            .padding(.trailing, NotchSettingsDrawerPresentation.rowTrailingPadding)
        }
    }

    // MARK: Other tabs

    private func tabEntry(_ tab: SettingsTab) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: tab.systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(palette.secondary.color)
            Text(tab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primary.color)
            Text(NotchSettingsDrawerPresentation.tabDescription(tab))
                .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            actionButton(NotchSettingsDrawerPresentation.openTabTitle(tab), prominent: true) {
                onOpenWindow(tab, nil)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    private func row(
        id: String, symbol: String, title: String, detail: String, tooltip: String? = nil, tint: Color? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? palette.secondary.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: NotchSettingsDrawerPresentation.titleFontSize))
                    .foregroundStyle(palette.primary.color)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: NotchSettingsDrawerPresentation.detailFontSize))
                    .foregroundStyle(palette.tertiary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PillControlTooltip(text: tooltip))
            trailing()
        }
        .padding(.leading, NotchSettingsDrawerPresentation.rowLeadingPadding)
        .padding(.trailing, NotchSettingsDrawerPresentation.rowTrailingPadding)
        .frame(height: NotchSettingsDrawerPresentation.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.primary.color.opacity(hoveredRow == id ? NotchHistoryPresentation.rowHoverOpacity : 0))
        )
        .onHover { hoveredRow = $0 ? id : (hoveredRow == id ? nil : hoveredRow) }
        .accessibilityElement(children: .combine)
    }

    private func actionButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        NotchDrawerButton(title: title, palette: palette, prominent: prominent, action: action)
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

/// The version row: the full build line (never truncated, wraps to a second line if it must), Check for
/// updates, and when a release is newer, its notes and an Update button.
struct NotchSettingsVersionRow: View {
    let updates: NotchUpdateController
    let palette: VoiceBarNotchContrastPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
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
