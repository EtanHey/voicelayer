import SwiftUI

/// A disclosure whose whole header row is the button, not just the caret.
///
/// AIDEV-NOTE: Ported from BrainBar's `BrainBarDisclosureRow` (brainlayer d5f64052, PR #889).
/// The stock macOS `DisclosureGroup` only toggles from its tiny caret: a click on the title or
/// the rest of the row does nothing, and VoiceOver's AXPress reported success without
/// expanding it (R4 UI pass finding 11). Keep the full-width content shape, and never make the
/// row separately focusable: that is what left BrainBar's mouse-click focus ring behind.
struct SettingsDisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse" : "Expand")

            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
