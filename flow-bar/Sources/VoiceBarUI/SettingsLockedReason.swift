import SwiftUI

/// Etan (QA 2026-11-11, shot 5, said twice): a switch that cannot be changed says why when you hover the switch
/// itself ("Unavailable with Parakeet", "Set by <VAR>", "Recording…"). The reason is never part of the row's text.
///
/// The switch reports where it is and whether it is hovered (`settingsLockedReason`); the row draws the bubble
/// (`settingsLockedReasonBubble`) outside its own dimming, so the reason reads at full strength beside a muted row.
struct SettingsLockedReasonPreference {
    let reason: String
    let bounds: Anchor<CGRect>
    let isShown: Bool
}

struct SettingsLockedReasonKey: PreferenceKey {
    static let defaultValue: SettingsLockedReasonPreference? = nil
    static func reduce(value: inout SettingsLockedReasonPreference?, nextValue: () -> SettingsLockedReasonPreference?) {
        value = value ?? nextValue()
    }
}

/// Timing for the bubble: a short rest before it shows so passing the pointer over a row does not flash it, then a
/// 150 ms ease-out in; it leaves at once (Emil: tooltips 125-200 ms, slow where the user decides, fast on exit).
enum SettingsLockedReasonMotion {
    static let showDelay: Duration = .milliseconds(180)
    static let fadeIn: Double = 0.15
    /// Space between the bubble's bottom and the switch's top.
    static let lift: CGFloat = 4
}

/// On the disabled switch. A nil reason leaves the switch untouched (no hover catcher over a live control).
struct SettingsLockedReasonSource: ViewModifier {
    let reason: String?
    @Environment(\.settingsHoverPreview) private var hoverPreview
    @State private var isHovered = false
    @State private var showTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                if reason != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onHover(perform: hover)
                        .accessibilityHidden(true)
                }
            }
            .anchorPreference(key: SettingsLockedReasonKey.self, value: .bounds) { anchor in
                reason.map { SettingsLockedReasonPreference(reason: $0, bounds: anchor, isShown: isHovered || hoverPreview.lockedReasons) }
            }
            .modifier(OptionalAccessibilityHint(text: reason))
            .onChange(of: reason) { _, new in if new == nil { hover(false) } }
    }

    private func hover(_ hovering: Bool) {
        showTask?.cancel()
        guard hovering else {
            isHovered = false
            return
        }
        showTask = Task { @MainActor in
            try? await Task.sleep(for: SettingsLockedReasonMotion.showDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: SettingsLockedReasonMotion.fadeIn)) { isHovered = true }
        }
    }
}

/// On the row, outside any `.opacity` that mutes it: draws the reason just above the switch, its trailing edge on the
/// switch's, so nothing on the row (title, badge, description) is covered (lead review, c7 07:55Z).
struct SettingsLockedReasonBubbleHost: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SettingsLockedReasonKey.self) { preference in
            GeometryReader { proxy in
                if let preference, preference.isShown {
                    let rect = proxy[preference.bounds]
                    SettingsReasonBubble(text: preference.reason)
                        .frame(width: rect.maxX, alignment: .trailing)
                        .offset(y: rect.minY - SettingsReasonBubble.height - SettingsLockedReasonMotion.lift)
                        .transition(reduceMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true) // the switch carries it as its hint
                }
            }
        }
    }
}

/// The bubble itself: a lock glyph and the reason, one line, solid so it reads over the row's text.
struct SettingsReasonBubble: View {
    static let fill = Color(nsColor: SettingsPanePalette.adaptive(
        light: SettingsPanePalette.RGB(0xFFFFFF), dark: SettingsPanePalette.RGB(0x3A3A3C),
        name: "VoiceBarSettingsReasonBubble"))
    static let font = Font.system(size: 11.5, weight: .medium)
    static let height: CGFloat = 22

    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SettingsPanePalette.helper)
            Text(text)
                .font(Self.font)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.fill)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

struct OptionalAccessibilityHint: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text { content.accessibilityHint(text) } else { content }
    }
}

extension View {
    /// The switch side: `reason` non-nil means the switch is locked and hovering it shows why.
    func settingsLockedReason(_ reason: String?) -> some View {
        modifier(SettingsLockedReasonSource(reason: reason))
    }

    /// The row side: put this after the row's dimming so the bubble is not dimmed with it.
    func settingsLockedReasonBubble() -> some View {
        modifier(SettingsLockedReasonBubbleHost())
    }
}

/// Snapshot-only: draws hover states offscreen, where there is no pointer (lane S before/after PNGs and layout
/// tests). The app never sets it.
struct SettingsHoverPreview: Equatable {
    var microphoneRow: Int?
    var lockedReasons = false
}

private struct SettingsHoverPreviewKey: EnvironmentKey {
    static let defaultValue = SettingsHoverPreview()
}

extension EnvironmentValues {
    var settingsHoverPreview: SettingsHoverPreview {
        get { self[SettingsHoverPreviewKey.self] }
        set { self[SettingsHoverPreviewKey.self] = newValue }
    }
}
