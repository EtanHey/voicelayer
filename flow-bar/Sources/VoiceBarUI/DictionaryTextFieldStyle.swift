import SwiftUI

extension View {
    /// Plain field text in the notch palette's primary ink, with its placeholder drawn here in note ink.
    ///
    /// AIDEV-NOTE: track D taste review P1: on macOS a TextField `prompt` takes the field's own foreground style, so a
    /// note-ink prompt rendered at primary ink and empty fields looked filled. The placeholder is therefore a separate
    /// Text behind the field, shown only while it is empty. The field itself has no prompt and an empty title: a
    /// prompt painted `Color.clear` stayed clear only on macOS 27, and macOS 26 painted it at primary ink (#968 CI and
    /// Etan's M1). VoiceOver gets the field's explicit `accessibilityLabel` (set by each caller) and the placeholder as
    /// its hint, read when the field is empty.
    func dictionaryTextField(placeholder: String, isEmpty: Bool) -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(NotchInk.primary)
            .accessibilityHint(isEmpty ? placeholder : "")
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
