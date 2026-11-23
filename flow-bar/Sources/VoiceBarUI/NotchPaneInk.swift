import SwiftUI

extension VoiceBarNotchContrastPalette {
    /// A red that reads on the notch glass, for errors (Etan's notch rules, 18 Nov: "a readable red from the palette,
    /// never system red on glass"). It must also read on the darkest stack it is drawn on: Delete's prominent capsule
    /// over the confirmation bar (#968 CodeRabbit; the earlier 0x8E1B1B / 0xFF8F87 fell to 3.3:1 / 4.0:1 there).
    /// Light 0x620F0F is 6.7:1 on the light glass (rgb 185), 4.81:1 on that capsule stack and 4.58:1 on the Transcription
    /// Delete's plate; dark 0xFFADA6 is 8.2:1 on the dark glass (rgb 41), 4.91:1 and 4.60:1 on the same stacks.
    /// `NotchPaneInkTests` pins every stack.
    public static func errorText(for appearance: VoiceBarNotchAppearance) -> VoiceBarRGBA {
        switch appearance {
        case .light: VoiceBarRGBA(red: 0x62 / 255, green: 0x0F / 255, blue: 0x0F / 255, alpha: 1)
        case .dark: VoiceBarRGBA(red: 1, green: 0xAD / 255, blue: 0xA6 / 255, alpha: 1)
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
    var note: Color { palette.primary.color.opacity(Self.noteOpacity(appearance)) }

    /// Dark keeps the read tier (64 %: 6.4:1 on the dark glass, rgb 41; 5.0:1 on a control plate). Light departs to
    /// 76 % because notes also sit on filled surfaces: on the darkest light glass measured (rgb 185) 70 % was 4.61:1
    /// bare but 4.27:1 on a field well and 4.18:1 on a selected row (#968 CodeRabbit). 76 % gives 5.36:1 bare, 4.90:1
    /// on a field well, 4.78:1 on a selected row and 4.67:1 on a control plate.
    static func noteOpacity(_ appearance: VoiceBarNotchAppearance) -> Double {
        appearance == .light ? 0.76 : TeleprompterA.Tier.read.opacity
    }

    /// The fills note ink is drawn on, as opacities of the palette primary (see the fills below). The contrast tests
    /// walk every one.
    static let fieldFillOpacity = 0.08, selectionFillOpacity = 0.10, controlFillOpacity = 0.12
    static let noteSurfaceFillOpacities: [Double] = [0, fieldFillOpacity, selectionFillOpacity, controlFillOpacity]
    /// Errors (a blocking conflict, a failed save).
    var error: Color { VoiceBarNotchContrastPalette.errorText(for: appearance).color }

    /// A text field's well and its hairline edge.
    var fieldFill: Color { palette.primary.color.opacity(Self.fieldFillOpacity) }
    var fieldStroke: Color { palette.primary.color.opacity(0.14) }
    /// A small control's plate (the swap button, a variant chip): the drawer button's resting fill.
    var controlFill: Color { palette.primary.color.opacity(Self.controlFillOpacity) }
    /// A selected list row; a just-saved row flashes at `flashFill`.
    var selectionFill: Color { palette.primary.color.opacity(Self.selectionFillOpacity) }
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
