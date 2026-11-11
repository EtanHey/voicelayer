import AppKit
import SwiftUI

/// Text colors for the Dictionary and Speech panes that must stay readable on the window background.
///
/// AIDEV-NOTE: `.secondary` caption text measured 3.19:1 in the prior review; helper copy needs at least 4.5:1 in
/// light and dark. The sRGB values are pinned by `SettingsPaneContrastTests` against the resolved window background.
enum SettingsPanePalette {
    struct RGB: Equatable {
        let red: Double, green: Double, blue: Double
        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }

    static let helperLight = RGB(0x595959)
    static let helperDark = RGB(0xADADAD)
    static let warningLight = RGB(0x9A4A00)
    static let warningDark = RGB(0xFFB340)

    static let helper = Color(nsColor: adaptive(
        light: helperLight, dark: helperDark, name: "VoiceBarSettingsHelperText"
    ))
    static let warning = Color(nsColor: adaptive(
        light: warningLight, dark: warningDark, name: "VoiceBarSettingsWarningText"
    ))

    static func adaptive(light: RGB, dark: RGB, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
        }
    }

    /// WCAG 2 contrast ratio between two sRGB colors.
    static func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: RGB) -> Double {
            0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let (high, low) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (high + 0.05) / (low + 0.05)
    }
}

/// Row anatomy (V12): title 13 pt and description 11.5 pt, each at most two lines and then an ellipsis. The full
/// text shows when the row is selected, and as a tooltip only when the rendered text is actually clipped.
struct SettingsRowLabel: View {
    static let titleFont = Font.system(size: 13, weight: .medium)
    static let descriptionFont = Font.system(size: 11.5)
    static let lineLimit = 2
    /// Trailing controls never squeeze the text column below this; they wrap under it instead.
    static let textMinWidth: CGFloat = 160

    let title: String
    let description: String?
    var badge: String?
    var titleBadge: SettingsPill?
    var isSelected = false
    /// The notch drawer wraps row copy in full (lead review, c7 07:55Z: "no truncated copy anywhere"); the window
    /// keeps the V12 two-line limit with a tooltip for the rest.
    @Environment(\.settingsRowWrapsFully) private var wrapsFully

    private var limit: Int? { isSelected || wrapsFully ? nil : Self.lineLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ClippingAwareText(text: title, font: Self.titleFont, lineLimit: limit)
                    .foregroundStyle(.primary)
                if let titleBadge { titleBadge }
            }
            if let description, !description.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ClippingAwareText(text: description, font: Self.descriptionFont,
                                      lineLimit: limit)
                        .foregroundStyle(SettingsPanePalette.helper)
                    if let badge { SettingsPill(text: badge) }
                }
            } else if let badge {
                SettingsPill(text: badge)
            }
        }
        .frame(minWidth: Self.textMinWidth, maxWidth: .infinity, alignment: .leading)
    }
}

/// A `Text` that knows whether its line limit actually cut it: it lays out the same string unconstrained, hidden, at
/// the same width, and compares heights. Only a clipped text gets a tooltip.
struct ClippingAwareText: View {
    let text: String
    let font: Font
    let lineLimit: Int?
    @State private var isClipped = false

    static func isClipped(fullHeight: CGFloat, limitedHeight: CGFloat) -> Bool {
        fullHeight > limitedHeight + 0.5
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .settingsTextAudit(text, font: font)
            .background(alignment: .topLeading) {
                GeometryReader { limited in
                    Text(text)
                        .font(font)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: limited.size.width, alignment: .leading)
                        .hidden()
                        .background(GeometryReader { full in
                            Color.clear
                                .onAppear { measure(full: full.size.height, limited: limited.size.height) }
                                .onChange(of: full.size.height) { _, height in
                                    measure(full: height, limited: limited.size.height)
                                }
                                .onChange(of: limited.size.height) { _, height in
                                    measure(full: full.size.height, limited: height)
                                }
                        })
                }
                .accessibilityHidden(true)
            }
            .modifier(OptionalHelp(text: isClipped && lineLimit != nil ? text : nil))
    }

    private func measure(full: CGFloat, limited: CGFloat) {
        let clipped = Self.isClipped(fullHeight: full, limitedHeight: limited)
        if clipped != isClipped { isClipped = clipped }
    }
}

struct OptionalHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// Row anatomy (V12) for a text column plus trailing controls: the controls keep their natural width beside the
/// text while the text column keeps at least `textMinWidth`; otherwise they wrap under the text.
///
/// AIDEV-NOTE: not `ViewThatFits`. That compares ideal sizes, and a wrapping Text's ideal width is its one-line
/// length, so any long description would push the controls under the text even in a wide window.
struct SettingsRowLayout: Layout {
    var spacing: CGFloat = 8
    var textMinWidth: CGFloat = SettingsRowLabel.textMinWidth

    static func wrapsControls(width: CGFloat, controlsWidth: CGFloat, spacing: CGFloat, textMinWidth: CGFloat) -> Bool {
        width - controlsWidth - spacing < textMinWidth
    }

    private struct Plan {
        let wraps: Bool
        let textSize: CGSize
        let controlsSize: CGSize
        let width: CGFloat
    }

    private func plan(width proposed: CGFloat?, subviews: Subviews) -> Plan {
        let controls = subviews[1].sizeThatFits(.unspecified)
        let width = proposed ?? (subviews[0].sizeThatFits(.unspecified).width + spacing + controls.width)
        let wraps = Self.wrapsControls(width: width, controlsWidth: controls.width, spacing: spacing,
                                       textMinWidth: textMinWidth)
        let textWidth = wraps ? width : width - controls.width - spacing
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        return Plan(wraps: wraps, textSize: CGSize(width: textWidth, height: text.height), controlsSize: controls,
                    width: width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let plan = plan(width: proposal.width, subviews: subviews)
        let height = plan.wraps
            ? plan.textSize.height + spacing / 2 + plan.controlsSize.height
            : max(plan.textSize.height, plan.controlsSize.height)
        return CGSize(width: plan.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let plan = plan(width: bounds.width, subviews: subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: plan.textSize.width, height: nil))
        // Beside the text, controls are centred on it (lane S DESIGN.md §3): a switch or button beside a two-line
        // row sits in the middle of the row, not on the title's line.
        let controlsOrigin = plan.wraps
            ? CGPoint(x: bounds.minX, y: bounds.minY + plan.textSize.height + spacing / 2)
            : CGPoint(x: bounds.maxX - plan.controlsSize.width,
                      y: bounds.minY + max(0, (plan.textSize.height - plan.controlsSize.height) / 2))
        subviews[1].place(at: controlsOrigin, anchor: .topLeading, proposal: ProposedViewSize(plan.controlsSize))
    }
}

private struct SettingsRowWrapsFullyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the notch drawer: row titles and descriptions wrap to as many lines as they need.
    var settingsRowWrapsFully: Bool {
        get { self[SettingsRowWrapsFullyKey.self] }
        set { self[SettingsRowWrapsFullyKey.self] = newValue }
    }
}
