import SwiftUI

/// C6 L2 (S9, N17): one motion vocabulary for the drawer's content switches, so a threshold or tab change reads
/// as the same surface changing, never as a one-frame cut ("tabbed History becomes blank", "Release History
/// becomes General", the grip turning into "Release for Settings" between two frames).
///
/// - Purpose: state indication plus preventing a jarring change. The shell's own spring keeps moving the surface;
///   only the content inside it crossfades, with a small blur that bridges the two states into one.
/// - Frequency: a threshold release is occasional (standard timing); a tab switch is tens a day, so it is faster
///   and has no movement.
/// - Curve: the strong ease-out (`cubic-bezier(0.23, 1, 0.32, 1)`); exits are faster than entries.
/// - Reduced motion: opacity only, no blur and no movement.
/// - The drawer content is drawn in the glass material's nested hosting view, which updates itself when the surface
///   model changes, so no outer transaction reaches it. `NotchDrawerCrossfade` keeps the shown key as its own
///   state inside that tree and animates its change there; a quick switch back retargets the running fade.
enum NotchDrawerMotion {
    /// History's list → the Settings drawer at the pull threshold, and back.
    static let contentInDuration: Double = 0.22
    static let contentOutDuration: Double = 0.14
    /// The incoming drawer settles down into place, the way the pull moved it.
    static let contentInOffset: CGFloat = -6
    static let contentBlur: CGFloat = 4

    /// A tab switch inside the Settings drawer: no movement, quicker.
    static let tabInDuration: Double = 0.16
    static let tabOutDuration: Double = 0.1
    static let tabBlur: CGFloat = 2

    /// The grip ↔ "Release for Settings" handoff (N17).
    static let hintInDuration: Double = 0.18
    static let hintOutDuration: Double = 0.12
    static let hintStartScale: CGFloat = 0.94
    static let hintBlur: CGFloat = 2

    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(
                insertion: .modifier(active: NotchDrawerSwap(opacity: 0, phase: .arriving), identity: .identity)
                    .animation(easeOut(contentInDuration)),
                removal: .modifier(active: NotchDrawerSwap(opacity: 0, phase: .leaving), identity: .identity)
                    .animation(easeOut(contentOutDuration))
            )
        }
        return .asymmetric(
            insertion: .modifier(
                active: NotchDrawerSwap(opacity: 0, blur: contentBlur, offset: contentInOffset, phase: .arriving),
                identity: .identity
            ).animation(easeOut(contentInDuration)),
            removal: .modifier(
                active: NotchDrawerSwap(opacity: 0, blur: contentBlur, offset: 0, phase: .leaving),
                identity: .identity
            ).animation(easeOut(contentOutDuration))
        )
    }

    static func tabTransition(reduceMotion: Bool) -> AnyTransition {
        let blur = reduceMotion ? 0 : tabBlur
        return .asymmetric(
            insertion: .modifier(active: NotchDrawerSwap(opacity: 0, blur: blur, phase: .arriving), identity: .identity)
                .animation(easeOut(tabInDuration)),
            removal: .modifier(active: NotchDrawerSwap(opacity: 0, blur: blur, phase: .leaving), identity: .identity)
                .animation(easeOut(tabOutDuration))
        )
    }

    static func hintTransition(reduceMotion: Bool) -> AnyTransition {
        func swap(_ phase: NotchDrawerSwapPhase) -> NotchDrawerSwap {
            reduceMotion ? NotchDrawerSwap(opacity: 0, phase: phase)
                : NotchDrawerSwap(opacity: 0, blur: hintBlur, scale: hintStartScale, phase: phase)
        }
        return .asymmetric(
            insertion: .modifier(active: swap(.arriving), identity: .identity).animation(easeOut(hintInDuration)),
            removal: .modifier(active: swap(.leaving), identity: .identity).animation(easeOut(hintOutDuration))
        )
    }

    /// The grip's fade while the hint takes its band (same timings, so the two cross in one beat).
    static func gripAnimation(showsGrip: Bool) -> Animation {
        easeOut(showsGrip ? hintInDuration : hintOutDuration)
    }
}

/// Shows `content(key)` and crossfades to the new content when `key` changes. The key is mirrored into local state
/// and changed under this view's own animation, so the switch animates wherever the view is hosted. The previous
/// content stays drawn for at most the one update before the mirror catches up (never a blank frame).
struct NotchDrawerCrossfade<Key: Hashable, Content: View>: View {
    let key: Key
    let animation: Animation
    let transition: AnyTransition
    let content: (Key) -> Content
    @State private var shown: Key

    init(key: Key, animation: Animation, transition: AnyTransition, @ViewBuilder content: @escaping (Key) -> Content) {
        self.key = key
        self.animation = animation
        self.transition = transition
        self.content = content
        _shown = State(initialValue: key)
    }

    var body: some View {
        ZStack(alignment: .top) {
            content(shown)
                .id(shown)
                .transition(transition)
        }
        .onChange(of: key) { _, next in
            withAnimation(animation) { shown = next }
        }
    }
}

/// Which side of a content switch a frame belongs to: the content leaving or the content arriving.
enum NotchDrawerSwapPhase: Equatable, Sendable {
    case resting
    case leaving
    case arriving
}

/// One frame of a drawer content switch as SwiftUI drew it (tests read these through the environment probe).
struct NotchDrawerSwapFrame: Equatable, Sendable {
    let phase: NotchDrawerSwapPhase
    let opacity: Double
}

#if DEBUG
/// Tests only (debug builds): sees every frame of a drawer content switch. The lower content is drawn in the glass
/// material's nested hosting view, which the SwiftUI environment does not reach, so this is a static hook.
@MainActor
enum NotchDrawerSwapProbe {
    static var observer: ((NotchDrawerSwapFrame) -> Void)?
}
#endif

/// Opacity, blur, scale and a vertical offset: every value is a transform, opacity or a cheap small blur. Animatable,
/// so each interpolated frame passes through `body` (debug builds report it to `NotchDrawerSwapProbe`).
struct NotchDrawerSwap: ViewModifier, Animatable {
    var opacity: Double = 1
    var blur: CGFloat = 0
    var scale: CGFloat = 1
    var offset: CGFloat = 0
    /// Not animated: the transition's target side, so a frame knows whether it is leaving or arriving.
    var phase: NotchDrawerSwapPhase = .resting

    static let identity = NotchDrawerSwap()

    var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(opacity, AnimatablePair(blur, AnimatablePair(scale, offset))) }
        set {
            opacity = newValue.first
            blur = newValue.second.first
            scale = newValue.second.second.first
            offset = newValue.second.second.second
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: offset)
            .onChange(of: opacity, initial: true) { _, _ in report() }
    }

    private func report() {
        #if DEBUG
        NotchDrawerSwapProbe.observer?(NotchDrawerSwapFrame(phase: phase, opacity: opacity))
        #endif
    }
}
