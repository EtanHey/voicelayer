import SwiftUI

extension VoiceBarNotchContrastPalette {
    /// A red that reads on the notch glass, for errors (Etan's notch rules, 18 Nov: "a readable red from the palette,
    /// never system red on glass"). Light 0x8E1B1B is 4.6:1 on the light glass (rgb 185) and 6.5:1 on 219; dark
    /// 0xFF8F87 is 6.6:1 on the dark glass (rgb 41). `NotchPaneInkTests` pins both.
    public static func errorText(for appearance: VoiceBarNotchAppearance) -> VoiceBarRGBA {
        switch appearance {
        case .light: VoiceBarRGBA(red: 0x8E / 255, green: 0x1B / 255, blue: 0x1B / 255, alpha: 1)
        case .dark: VoiceBarRGBA(red: 1, green: 0x8F / 255, blue: 0x87 / 255, alpha: 1)
        }
    }
}

/// The ink and fills a Settings pane draws with on the notch glass, all from the shared notch palette
/// (`VoiceBarNotchContrastPalette`), never system semantic colours. A pane resolves it from its colour scheme, which the
/// drawer sets from the notch appearance; the Settings window resolves the same ink for its own appearance.
struct NotchPaneInk {
    let appearance: VoiceBarNotchAppearance
    let palette: VoiceBarNotchContrastPalette

    init(_ appearance: VoiceBarNotchAppearance) {
        self.appearance = appearance
        palette = .resolve(for: appearance)
    }

    init(colorScheme: ColorScheme) {
        self.init(colorScheme == .dark ? .dark : .light)
    }

    /// Titles, field text, term names.
    var primary: Color { palette.primary.color }
    /// Notes, placeholders, variants and helper glyphs: the teleprompter's non-current (read) word ink.
    var note: Color { palette.primary.color.opacity(TeleprompterA.Tier.read.opacity) }
    /// Errors (a blocking conflict, a failed save).
    var error: Color { VoiceBarNotchContrastPalette.errorText(for: appearance).color }

    /// A text field's well and its hairline edge.
    var fieldFill: Color { palette.primary.color.opacity(0.08) }
    var fieldStroke: Color { palette.primary.color.opacity(0.14) }
    /// A small control's plate (the swap button, a variant chip): the drawer button's resting fill.
    var controlFill: Color { palette.primary.color.opacity(0.12) }
    /// A selected list row; a just-saved row flashes at `flashFill`.
    var selectionFill: Color { palette.primary.color.opacity(0.10) }
    var flashFill: Color { palette.primary.color.opacity(0.20) }
    /// Row separators and bar edges.
    var hairline: Color { palette.primary.color.opacity(0.10) }
    /// A bar laid over the pane's bottom edge (delete confirmation, Undo): the palette's surface tint.
    var barFill: Color { palette.surfaceTint.color }
}

/// The notch text-field well: palette fill and hairline, 7 pt corners. One place for every Dictionary field.
struct NotchFieldWell: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let ink = NotchPaneInk(colorScheme: colorScheme)
        content
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ink.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ink.fieldStroke, lineWidth: 1))
    }
}

/// `NotchPaneInk` as a shape style, resolved from the view's colour scheme where it is drawn, for views that have no
/// environment of their own to read (static row builders): `.foregroundStyle(NotchInk.note)`.
enum NotchInk: ShapeStyle {
    case primary, note, error, hairline, selection, flash, control, bar

    func resolve(in environment: EnvironmentValues) -> Color {
        let ink = NotchPaneInk(colorScheme: environment.colorScheme)
        switch self {
        case .primary: return ink.primary
        case .note: return ink.note
        case .error: return ink.error
        case .hairline: return ink.hairline
        case .selection: return ink.selectionFill
        case .flash: return ink.flashFill
        case .control: return ink.controlFill
        case .bar: return ink.barFill
        }
    }
}

/// A Dictionary row separator or bar edge: a palette hairline instead of the system Divider, one point tall so rows
/// keep the pitch the Divider gave them (`DictionaryActionCapAlignmentTests`).
struct DictionaryHairline: View {
    var body: some View {
        Rectangle().fill(NotchInk.hairline).frame(height: 1).frame(maxWidth: .infinity)
    }
}
