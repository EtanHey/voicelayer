import SwiftUI

extension View {
    /// Plain field text in the notch palette's primary ink.
    func dictionaryTextField() -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(NotchInk.primary)
    }

    /// The notch field well (`NotchFieldWell`): palette fill and hairline, no system text background.
    func dictionaryFieldContainer() -> some View {
        modifier(NotchFieldWell())
    }
}
