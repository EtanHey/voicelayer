import SwiftUI

/// One Settings row (V12 row anatomy): an optional leading mark, the two-line title and description, and trailing
/// controls that keep their natural width and wrap under the text when the window is too narrow.
struct SettingsRow<Lead: View, Trailing: View>: View {
    let title: String
    var description: String?
    /// A status pill that sits on the description line, after it (the mic in use: "Connected · Used for dictation").
    var badge: String?
    var isSelected = false
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsRowLayout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                lead()
                SettingsRowLabel(title: title, description: description, badge: badge, isSelected: isSelected)
            }
            HStack(spacing: 6) { trailing() }
                .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Lead == EmptyView {
    init(title: String, description: String? = nil, badge: String? = nil, isSelected: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, description: description, badge: badge, isSelected: isSelected,
                  lead: { EmptyView() }, trailing: trailing)
    }
}

/// The small status capsule a row can carry ("Used for dictation", "Recommended").
struct SettingsPill: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
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
