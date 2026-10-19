import SwiftUI

/// The one Settings drawer: General › Advanced's look and animation, used by every expandable section.
///
/// AIDEV-NOTE: Ported from BrainBar's `BrainBarDisclosureRow` (brainlayer d5f64052, PR #889).
/// The stock macOS `DisclosureGroup` only toggles from its tiny caret: a click on the title or
/// the rest of the row does nothing, and VoiceOver's AXPress reported success without
/// expanding it (R4 UI pass finding 11). Keep the full-width content shape, and never make the
/// row separately focusable: that is what left BrainBar's mouse-click focus ring behind.
/// SETUI1 (Etan, 2026-10-19): "reuse that one" — never hand-roll another chevron row in Settings.
struct SettingsDisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsDisclosureHeader(title, isExpanded: $isExpanded)
            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The drawer's header on its own, for a list that must keep its rows lazy (the Dictionary): the caller
/// places the rows itself, directly in its `LazyVStack`, under `if isExpanded`.
struct SettingsDisclosureHeader<Label: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    /// false: nothing to open (the chevron keeps its column but is hidden, and the row is not a button).
    let isEnabled: Bool
    let hint: String?
    @ViewBuilder let label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        isEnabled: Bool = true,
        hint: String? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.hint = hint
        self.label = label
    }

    var body: some View {
        if isEnabled {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(hint ?? (isExpanded ? "Collapse" : "Expand"))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isEnabled ? 1 : 0)
                .accessibilityHidden(true)
            label()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SettingsDisclosureHeader where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, isEnabled: Bool = true, hint: String? = nil) {
        self.init(title, isExpanded: isExpanded, isEnabled: isEnabled, hint: hint) { Text(title) }
    }
}
