import SwiftUI

/// The field's native placeholder, kept so AppKit and VoiceOver still report it (AXPlaceholderValue), but painted clear:
/// the visible placeholder is the note-ink layer `dictionaryTextField(placeholder:isEmpty:)` draws.
func dictionaryPrompt(_ text: String) -> Text {
    Text(text).foregroundStyle(Color.clear)
}

extension View {
    /// Plain field text in the notch palette's primary ink, with its placeholder drawn here in note ink.
    ///
    /// AIDEV-NOTE: track D taste review P1: on macOS a TextField `prompt` takes the field's own foreground style, so a
    /// note-ink prompt rendered at primary ink and empty fields looked filled. The placeholder is therefore a separate
    /// Text behind the field, shown only while it is empty; the native prompt stays for VoiceOver (`dictionaryPrompt`).
    func dictionaryTextField(placeholder: String, isEmpty: Bool) -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(NotchInk.primary)
            .background(alignment: .leading) {
                if isEmpty {
                    Text(placeholder)
                        .foregroundStyle(NotchInk.note)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// The notch field well (`NotchFieldWell`): palette fill and hairline, no system text background.
    func dictionaryFieldContainer() -> some View {
        modifier(NotchFieldWell())
    }
}
