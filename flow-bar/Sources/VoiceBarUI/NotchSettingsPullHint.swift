import SwiftUI

/// The pull hint is centred in the clear space below the list fade.
struct NotchSettingsPullHint: View {
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape")
            Text(NotchHistoryPresentation.settingsPullHint)
        }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .frame(height: NotchHistoryPresentation.settingsPullHintHeight, alignment: .center)
            .background(Capsule(style: .continuous).fill(ink.opacity(0.14)))
            // C6 L2 (N17): it takes over from the grip in one crossfade (the grip fades on the same beat).
            .transition(NotchDrawerMotion.hintTransition(reduceMotion: reduceMotion))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(NotchHistoryPresentation.settingsPullHintIdentifier)
    }
}
