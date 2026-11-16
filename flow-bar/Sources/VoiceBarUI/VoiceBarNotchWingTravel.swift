import Observation
import SwiftUI

/// Owner r2 (2.4.3, N11b), icons travel with the wing: every wing control keeps its settled distance from its wing's
/// OUTER end on every frame of a morph, so opening carries the icons out from under the notch and closing carries
/// them back in. Before, the controls sat at their settled places from the first frame and the growing glass
/// uncovered them (the mic cut in half, the chevron sitting where the wing ended).
///
/// The wing content is hosted inside the native glass (`VoiceBarGlassMaterial`), whose own hosting view gets no
/// animation: only the glass shape is interpolated per frame. So the shape hands its drawn wings to the content
/// through the environment, and each wing slot is offset by how far its drawn outer edge is from its settled one.
public struct VoiceBarNotchLiveWings: Equatable, Sendable {
    public let leading: CGFloat
    public let trailing: CGFloat

    public init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }
}

/// A shell shape that can say which wings it draws on this frame.
public protocol VoiceBarNotchLiveWingsProviding {
    var liveWings: VoiceBarNotchLiveWings? { get }
}

extension VoiceBarNotchContinuousShape: VoiceBarNotchLiveWingsProviding {
    public var liveWings: VoiceBarNotchLiveWings? {
        VoiceBarNotchLiveWings(leading: geometry.leadingWingWidth, trailing: geometry.trailingWingWidth)
    }
}

private struct VoiceBarNotchLiveWingsKey: EnvironmentKey {
    static let defaultValue: VoiceBarNotchLiveWings? = nil
}

extension EnvironmentValues {
    /// The wings the shell draws on this frame; nil outside a morphing shell (no travel).
    public var voiceBarNotchLiveWings: VoiceBarNotchLiveWings? {
        get { self[VoiceBarNotchLiveWingsKey.self] }
        set { self[VoiceBarNotchLiveWingsKey.self] = newValue }
    }
}

/// Offsets one settled wing slot so its outer end rides the drawn outer edge. A leading slot moves right (toward the
/// notch) while its wing is drawn narrower than settled and left while wider; a trailing slot mirrors it. The slot
/// clips its own content, so what rides under the notch is covered by the black core.
struct VoiceBarNotchWingTravel: ViewModifier {
    let side: VoiceBarNotchSide
    let settledWidth: CGFloat
    let isEnabled: Bool
    @Environment(\.voiceBarNotchLiveWings) private var live

    func body(content: Content) -> some View {
        content.offset(x: isEnabled ? Self.offset(side: side, settledWidth: settledWidth, live: live) : 0)
    }

    static func offset(side: VoiceBarNotchSide, settledWidth: CGFloat, live: VoiceBarNotchLiveWings?) -> CGFloat {
        guard let live else { return 0 }
        return switch side {
        case .leading: settledWidth - live.leading
        case .trailing: live.trailing - settledWidth
        }
    }
}

/// The band a shell is closing to hidden from: its settled geometry, the band state its slots were laid out for and
/// its content. While it is set the shell keeps that content in its wings and lets it ride inward with the closing
/// glass, instead of dropping the glass and the icons in one frame.
struct VoiceBarNotchClosingBand: Equatable {
    let serial: Int
    let geometry: VoiceBarNotchGeometry
    let bandState: VoiceBarNotchVisualState
    let trailingLayoutState: VoiceBarNotchVisualState?
}

@Observable
final class VoiceBarNotchClosingTracker {
    var band: VoiceBarNotchClosingBand?
    /// The last visible band's wing content. Recorded while the band shows; read only while it closes.
    @ObservationIgnored var leading: AnyView?
    @ObservationIgnored var trailing: AnyView?
}
