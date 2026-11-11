import SwiftUI

/// Keep the focus target outside the transparent content. Putting opacity on the focus target itself removes
/// an unrevealed action from SwiftUI's key loop, so Tab can never reveal it. Space uses the same action as a click.
struct SettingsRowActionReveal: ViewModifier {
    let visible: Bool
    var enabled = true
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .focusable(enabled, interactions: .edit)
            .focusEffectDisabled(false)
            .onKeyPress(.space) {
                guard enabled else { return .ignored }
                action()
                return .handled
            }
    }
}
