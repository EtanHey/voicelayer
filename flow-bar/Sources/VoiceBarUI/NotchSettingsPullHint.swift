import SwiftUI

/// The pull hint lives in the grip band, whose proposal is narrower than its text.
struct NotchSettingsPullHint: View {
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(NotchHistoryPresentation.settingsPullHint, systemImage: "gearshape")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .frame(height: NotchHistoryPresentation.settingsPullHintHeight)
            .background(Capsule(style: .continuous).fill(ink.opacity(0.14)))
            // C6 L2 (N17): it takes over from the grip in one crossfade (the grip fades on the same beat).
            .transition(NotchDrawerMotion.hintTransition(reduceMotion: reduceMotion))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(NotchHistoryPresentation.settingsPullHintIdentifier)
    }
}
