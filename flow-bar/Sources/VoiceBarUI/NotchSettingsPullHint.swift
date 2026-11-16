import SwiftUI

/// A single capsule keeps its identity while the grip becomes the release hint.
struct NotchSettingsPullHint: View {
    let ink: Color
    var progress: CGFloat = 1
    @State private var identity = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func phase(_ progress: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? (progress >= 1 ? 1 : 0) : min(1, max(0, progress))
    }

    var body: some View {
        let p = Self.phase(progress, reduceMotion: reduceMotion)
        let labelWidth = (NotchHistoryPresentation.settingsPullHint as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 35
        Capsule(style: .continuous)
            .fill(ink.opacity(0.14 + (1 - p) * (NotchHistoryMorph.handleOpacity - 0.14)))
            .frame(width: NotchHistoryMorph.handleWidth + (labelWidth - NotchHistoryMorph.handleWidth) * p,
                   height: NotchHistoryMorph.handleThickness + (NotchHistoryPresentation.settingsPullHintHeight - NotchHistoryMorph.handleThickness) * p)
            .overlay {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text(NotchHistoryPresentation.settingsPullHint)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink)
                .fixedSize()
                .opacity(Double(max(0, (p - 0.8) / 0.2)))
            }
            .animation(reduceMotion ? nil : .spring(response: NotchHistoryMorph.springResponse,
                       dampingFraction: NotchHistoryMorph.springDampingFraction), value: p)
            #if DEBUG
            .onChange(of: progress, initial: true) { _, value in
                NotchPullHintProbe.observer?(identity, value)
            }
            #endif
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NotchHistoryPresentation.settingsPullHint)
            .accessibilityHidden(p < 1)
            .accessibilityIdentifier(NotchHistoryPresentation.settingsPullHintIdentifier)
    }
}

#if DEBUG
@MainActor enum NotchPullHintProbe {
    static var observer: ((UUID, CGFloat) -> Void)?
}
#endif
