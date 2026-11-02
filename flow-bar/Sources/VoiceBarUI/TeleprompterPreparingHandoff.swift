import SwiftUI

/// R2-04 (QA 2026-11-02, recording 2 @ 18.2 s): "Preparing speech…" crossfaded with the first chunk's text, so a
/// faded status was drawn over the reading text. The two now hand off in sequence: whichever is leaving fades out
/// completely before the other starts to fade in. Presentation only; when the switch happens is unchanged.
public enum TeleprompterPreparingHandoff {
    /// The leaving view: quick, so the reader is not kept waiting.
    public static let exitDuration: TimeInterval = 0.1
    /// One 60 Hz frame of clear air between the two, so no rendered frame holds both.
    public static let gap: TimeInterval = 1.0 / 60
    public static let enterDelay: TimeInterval = exitDuration + gap
    public static let enterDuration: TimeInterval = 0.18

    /// Used by both the status and the text, in either direction (a new read can return to "Preparing").
    public static var transition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: enterDuration).delay(enterDelay)),
            removal: .opacity.animation(.easeOut(duration: exitDuration))
        )
    }

    /// The opacity the transition gives a view `elapsed` seconds after the switch. Leaving reaches 0 at
    /// `exitDuration` and stays there; entering is 0 until `enterDelay`.
    public static func opacity(isEntering: Bool, elapsed: TimeInterval) -> Double {
        if isEntering {
            let progress = min(1, max(0, (elapsed - enterDelay) / enterDuration))
            return easeOut(progress)
        }
        let progress = min(1, max(0, elapsed / exitDuration))
        return 1 - easeOut(progress)
    }

    /// The same curve shape as SwiftUI's `.easeOut` (cubic-bezier 0, 0, 0.58, 1) at its end points: it is 0 only
    /// at 0 and 1 only at 1, which is all the no-overlap property depends on.
    private static func easeOut(_ t: Double) -> Double {
        1 - (1 - t) * (1 - t)
    }
}
