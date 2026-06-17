import SwiftUI

extension View {
    func dictionaryTextField() -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(.primary)
    }

    func dictionaryFieldContainer() -> some View {
        padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
