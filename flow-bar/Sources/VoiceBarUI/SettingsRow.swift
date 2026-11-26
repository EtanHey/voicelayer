import SwiftUI

/// One Settings row (V12 row anatomy): an optional leading mark, the two-line title and description, and trailing
/// controls that keep their natural width and wrap under the text when the window is too narrow.
struct SettingsRow<Lead: View, Trailing: View>: View {
    let title: String
    var description: String?
    /// A status pill that sits on the description line, after it (the mic in use: "Connected · Used for dictation").
    var badge: String?
    /// A pill on the title line, after the title ("Smart chunks [Experimental]"), so the trailing column holds only
    /// the row's control and the description gets the full text column.
    var titleBadge: SettingsPill?
    var isSelected = false
    // Small microphone buttons are 20 pt high; reserve that status-line height even with no badge/action.
    var controlsFollowStatus = false
    /// The text column's minimum before the controls wrap under it. A one-word title ("Rate") can give its wide
    /// control (a slider) the room instead (lane S PR 3).
    var textMinWidth: CGFloat = SettingsRowLabel.textMinWidth
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsRowLayout(controlsFollowStatus: controlsFollowStatus, textMinWidth: textMinWidth) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                lead()
                SettingsRowLabel(title: title, description: description, badge: badge, titleBadge: titleBadge,
                                 isSelected: isSelected,
                                 statusLineMinHeight: controlsFollowStatus ? 20 : nil)
            }
            HStack(spacing: 6) { trailing() }
                .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Lead == EmptyView {
    init(title: String, description: String? = nil, badge: String? = nil, titleBadge: SettingsPill? = nil,
         isSelected: Bool = false, textMinWidth: CGFloat = SettingsRowLabel.textMinWidth,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, description: description, badge: badge, titleBadge: titleBadge,
                  isSelected: isSelected, textMinWidth: textMinWidth, lead: { EmptyView() }, trailing: trailing)
    }
}

/// The small status capsule a row can carry ("Used for dictation", "Recommended").
struct SettingsPill: View {
    let text: String
    /// nil: the notch palette's neutral pill (2.4.6 track T: no system accent on the glass).
    var tint: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = NotchPaneInk(colorScheme: colorScheme)
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill((tint ?? ink.primary).opacity(0.18)))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SettingsControlFrameKey.self,
                    value: ["status-pill-\(text)": proxy.frame(in: .global)])
            })
            .fixedSize()
    }
}

/// Glyph colours for the setup marks. System green and orange measured 2.1 to 2.3:1 on the light window, under the
/// 3:1 floor for meaningful graphics; these keep 3:1 in light and dark (pinned by the U3a contrast tests).
enum SettingsMarkPalette {
    static let doneLight = SettingsPanePalette.RGB(0x1E7B34)
    static let doneDark = SettingsPanePalette.RGB(0x32D74B)
    static let done = Color(nsColor: SettingsPanePalette.adaptive(light: doneLight, dark: doneDark,
                                                                  name: "VoiceBarSettingsDoneMark"))
    /// The done green for a notch appearance (the drawer knows its appearance, not an NSAppearance).
    static func color(done appearance: VoiceBarNotchAppearance) -> Color {
        (appearance == .dark ? doneDark : doneLight).nsColor.swiftUIColor
    }
}

private extension NSColor {
    var swiftUIColor: Color { Color(nsColor: self) }
}

/// A pane's small action button. On the notch glass it is the drawer's own capsule (`NotchDrawerButton`, palette ink
/// and fill); in the legacy Settings window it stays the system small button.
struct SettingsPaneButton: View {
    let title: String
    var isEnabled = true
    var prominent = false
    let action: () -> Void
    @Environment(\.notchPaneInk) private var notchInk

    var body: some View {
        if let notchInk {
            NotchDrawerButton(title: title, palette: notchInk.palette, prominent: prominent, isEnabled: isEnabled,
                              action: action)
        } else {
            Button(title, action: action)
                .controlSize(.small)
                .fixedSize()
                .disabled(!isEnabled)
        }
    }
}

/// The leading mark of a setup step: done, on its way (loading or recovering by itself), or needing attention.
/// State is never colour-only: the glyphs differ too.
struct SettingsSetupMark: View {
    enum Kind { case done, pending, attention }
    let kind: Kind

    init(kind: Kind) { self.kind = kind }
    init(isDone: Bool) { kind = isDone ? .done : .attention }

    var body: some View {
        Image(systemName: kind == .done ? "checkmark.circle.fill"
            : kind == .pending ? "clock.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(kind == .done ? SettingsMarkPalette.done
                : kind == .pending ? SettingsPanePalette.helper : SettingsPanePalette.warning)
            .accessibilityLabel(kind == .done ? "Done" : kind == .pending ? "In progress" : "Needs attention")
    }
}

/// V12 audit: a visible row text publishes the string, font and frame it was laid out in, so the row-clipping guard
/// can compare the pixels actually drawn there with an unclipped two-line, tail-truncated reference. Nothing in the
/// app reads the preference.
struct SettingsTextAuditEntry: Equatable {
    let text: String
    let font: Font
    let frame: CGRect
}

struct SettingsTextAuditKey: PreferenceKey {
    static let defaultValue: [SettingsTextAuditEntry] = []
    static func reduce(value: inout [SettingsTextAuditEntry], nextValue: () -> [SettingsTextAuditEntry]) {
        value += nextValue()
    }
}

extension View {
    func settingsTextAudit(_ text: String, font: Font) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsTextAuditKey.self,
                                   value: [SettingsTextAuditEntry(text: text, font: font, frame: proxy.frame(in: .global))])
        })
    }
}

/// Geometry receipt for hosted layout checks; no product state or behavior reads this preference.
struct SettingsControlFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// A pane's short text field. On the notch glass it is the shared notch field well (palette fill and hairline, primary
/// ink), never the system's text background; in the legacy Settings window it stays the rounded system field.
struct SettingsPaneField: ViewModifier {
    let width: CGFloat
    @Environment(\.notchPaneInk) private var notchInk

    func body(content: Content) -> some View {
        if let notchInk {
            // D's field well (`NotchFieldWell`, NotchPaneInk.swift) adds 8 pt either side.
            content
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(notchInk.primary)
                .frame(width: width - 16)
                .modifier(NotchFieldWell())
        } else {
            content
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}

extension View {
    func settingsPaneField(width: CGFloat) -> some View { modifier(SettingsPaneField(width: width)) }
}

private struct NotchPaneInkKey: EnvironmentKey {
    static let defaultValue: NotchPaneInk? = nil
}

extension EnvironmentValues {
    /// Set by the notch Settings drawer on every pane it hosts (2.4.6 track S): shared row pieces (`SettingsRowLabel`,
    /// `SettingsPaneButton`, `SettingsPaneField`) draw from it on the glass. Nil in the legacy Settings window, whose
    /// rows keep their window ink and system controls.
    var notchPaneInk: NotchPaneInk? {
        get { self[NotchPaneInkKey.self] }
        set { self[NotchPaneInkKey.self] = newValue }
    }
}

/// Control inks for the drawer's native controls (2.4.6 track S, lead ruling 23 Nov): a switch's on-state takes the
/// notch's processing blue (`Theme.transcribingSpinnerColor`: 7.0:1 on the dark glass, 3.28:1 on the light glass,
/// so the white knob and the track both read), never the system accent.
enum NotchControlInk {
    static func switchOn(_ ink: NotchPaneInk) -> Color { Theme.transcribingSpinnerColor(for: ink.appearance) }
}

/// Every Settings switch (`.toggleStyle(.settingsSwitch)`). On the notch glass it draws its own track and knob from the
/// palette: the on-state in `NotchControlInk.switchOn`, the off track in the palette's subtle track. A system switch
/// in a panel that is not key draws its on-state grey whatever the tint, so the drawer cannot rely on `.tint`. In the
/// legacy Settings window (no `notchPaneInk`) it is the system switch, unchanged. VoiceOver reads it as the system
/// toggle (`accessibilityRepresentation`).
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SettingsSwitch(configuration: configuration) }
}

extension ToggleStyle where Self == SettingsSwitchToggleStyle {
    static var settingsSwitch: SettingsSwitchToggleStyle { SettingsSwitchToggleStyle() }
}

struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.notchPaneInk) private var notchInk
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 32, height: 19)
    static let knobInset: CGFloat = 2
    static var knobDiameter: CGFloat { size.height - 2 * knobInset }

    var body: some View {
        if let notchInk {
            let isOn = configuration.isOn
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(isOn ? NotchControlInk.switchOn(notchInk) : notchInk.palette.subtleTrack.color)
                    // A fixed square: a bare Circle fills the padded frame and sits centred whatever the alignment
                    // (#968 CodeRabbit), so the knob would not move between off and on.
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                        .padding(Self.knobInset)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// The closed surface of a drawer menu (the Speech voice picker): the current choice and an up-down chevron on the
/// drawer button's capsule, in palette ink. The native menu still opens on click.
struct NotchPickerLabel: View {
    let title: String
    let ink: NotchPaneInk
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
        }
        .fixedSize()
        .foregroundStyle(ink.primary.opacity(isEnabled ? 1 : 0.45))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(ink.controlFill))
        .contentShape(Capsule())
    }
}
