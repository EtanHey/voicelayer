import SwiftUI

/// One Settings row (V12 row anatomy): an optional leading mark, the two-line title and description, and trailing
/// controls that keep their natural width and wrap under the text when the window is too narrow.
struct SettingsRow<Lead: View, Trailing: View>: View {
    let title: String
    var description: String?
    var isSelected = false
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsRowLayout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                lead()
                SettingsRowLabel(title: title, description: description, isSelected: isSelected)
            }
            HStack(spacing: 6) { trailing() }
                .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Lead == EmptyView {
    init(title: String, description: String? = nil, isSelected: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, description: description, isSelected: isSelected, lead: { EmptyView() },
                  trailing: trailing)
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

/// The leading check or warning mark of a setup step. State is never colour-only: the glyphs differ too.
struct SettingsSetupMark: View {
    let isDone: Bool

    var body: some View {
        Image(systemName: isDone ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(isDone ? SettingsMarkPalette.done : SettingsPanePalette.warning)
            .accessibilityLabel(isDone ? "Done" : "Needs attention")
    }
}
