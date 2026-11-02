import CoreGraphics
import Foundation

public enum VoiceBarNotchMotionComponent: Equatable, Hashable, Sendable {
    case wings
    case panel
    case content
    case hardwareCore
}

public enum VoiceBarNotchAnimationKind: Equatable, Sendable {
    case spring
    case opacity
}

/// `NSGlassEffectView` performs its own WindowServer order-out treatment. At
/// the playback edge, give SwiftUI one committed frame to clear the hosted
/// subtitle before removing that glass so no readable text is ever composited
/// over an already exposed application.
public enum VoiceBarNotchPlaybackEdgeCommitPolicy {
    public static let glassRemovalDelay: TimeInterval = 0.05

    public static func stagesContentBeforeGlass(
        from source: VoiceMode,
        to destination: VoiceMode
    ) -> Bool {
        source == .speaking && destination == .idle
    }
}

/// NOTCH2: one shell change, as the view animates it. The geometry, the corner radii and the core-anchored
/// reveal mask all move in this single transaction, so they share one spring and one delay. The mask used to
/// start a run-loop turn after the geometry, on its own transaction, and that lag showed as a hard vertical cut
/// on the far wing while the shell opened.
public struct VoiceBarNotchShellTransition: Equatable, Sendable {
    /// Seconds the shell waits before it moves. A shrinking lower surface waits for its content (a transient
    /// note, the teleprompter, History) to fade out first, so no frame shows text against a moving edge.
    public let delay: TimeInterval
    /// Where the reveal mask settles: 0 collapses it onto the hardware core, 1 opens it to the whole canvas.
    public let revealProgress: CGFloat

    public static func resolve(
        from current: VoiceBarNotchGeometry,
        to next: VoiceBarNotchGeometry,
        visualState: VoiceBarNotchVisualState
    ) -> VoiceBarNotchShellTransition {
        // R0856-05: a top-row wing that must grow never waits. Waiting held the old, narrower wing in place
        // while its new controls (Stop and Cancel after History) were already drawn, clipped by its edge.
        let wingGrows = next.leadingWingWidth > current.leadingWingWidth + 0.5
            || next.trailingWingWidth > current.trailingWingWidth + 0.5
        return VoiceBarNotchShellTransition(
            delay: next.lowerSurfaceHeight < current.lowerSurfaceHeight && !wingGrows
                ? VoiceBarNotchContract.motion.contentExitDuration
                : 0,
            revealProgress: visualState == .idle ? 0 : 1
        )
    }

    /// N1: where the shell's spring actually starts and ends. A bodiless shell's body extents are invisible, so
    /// they are rewritten to the note tab's before a tab opens and kept at the tab's while it closes. The tab then
    /// drops straight down from under the notch and rises back into it; interpolating the extents instead swept a
    /// wing-wide slab inward across the first and last frames. Any other morph (History, the teleprompter) starts
    /// from the extents flush with the wings, as before.
    public static func morphEndpoints(
        from current: VoiceBarNotchGeometry,
        to next: VoiceBarNotchGeometry
    ) -> (start: VoiceBarNotchGeometry, end: VoiceBarNotchGeometry) {
        var start = current
        // Only a visible bodiless shell (one with wings) is rewritten. From idle the wings grow with the tab, and
        // that morph keeps the reveal mask on its single synchronous spring.
        if current.lowerSurfaceHeight == 0, next.lowerSurfaceHeight > 0,
           current.leadingWingWidth + current.trailingWingWidth > 0 {
            let flush = current.bodyFlushWithWings
            start = current.withBodyExtents(
                leading: next.bodyLeadingExtent < next.leadingWingWidth
                    ? next.bodyLeadingExtent : flush.bodyLeadingExtent,
                trailing: next.bodyTrailingExtent < next.trailingWingWidth
                    ? next.bodyTrailingExtent : flush.bodyTrailingExtent
            )
        }
        var end = next
        if next.lowerSurfaceHeight == 0, current.lowerSurfaceHeight > 0 {
            let flush = next.bodyFlushWithWings
            end = next.withBodyExtents(
                leading: current.bodyLeadingExtent < current.leadingWingWidth
                    ? min(current.bodyLeadingExtent, next.leadingWingWidth) : flush.bodyLeadingExtent,
                trailing: current.bodyTrailingExtent < current.trailingWingWidth
                    ? min(current.bodyTrailingExtent, next.trailingWingWidth) : flush.bodyTrailingExtent
            )
        }
        return (start, end)
    }
}

extension VoiceBarNotchGeometry {
    func withBodyExtents(leading: CGFloat, trailing: CGFloat) -> VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: coreWidth, topHeight: topHeight,
            leadingWingWidth: leadingWingWidth, trailingWingWidth: trailingWingWidth,
            bodyLeadingExtent: leading, bodyTrailingExtent: trailing,
            lowerSurfaceHeight: lowerSurfaceHeight
        )
    }
}

/// R0856-05: controls that arrive with a growing wing appear once the wing's glass covers them, instead of being
/// drawn clipped against the edge it is still growing past. Controls already in the wing are untouched.
public enum VoiceBarNotchWingContentEntry {
    public static let duration: TimeInterval = 0.12
    /// How far inside the growing glass edge a control's outer edge must be before it shows: clear of the
    /// wing's 15 pt rounded outer corner at the control's lower edge (NotchRecordingFromHistoryTests).
    static let coverMargin: CGFloat = 6

    /// The wait before controls arriving with a wing that grows by `growth` points show: the time the shell's
    /// spring takes to bring the glass past their outer edge. Zero when the wing does not grow, or grows out of
    /// a collapsed notch, whose core-anchored reveal is the opening itself.
    public static func delay(forGrowth growth: CGFloat) -> TimeInterval {
        guard growth > 0.5 else { return 0 }
        let needed = Double(max(0, min(1,
            1 - (VoiceBarNotchContract.material.compactContentInset - coverMargin) / growth)))
        let motion = VoiceBarNotchContract.motion
        var x = 0.0, v = 0.0, t = 0.0
        let dt = 0.0005
        while x < needed, t < 0.5 {
            let a = (-motion.stiffness * (x - 1) - motion.damping * v) / motion.mass
            v += a * dt
            x += v * dt
            t += dt
        }
        // Round up to whole 120 Hz frames.
        return (t * 120).rounded(.up) / 120
    }

    /// Whether an entering control is drawn at all `elapsed` seconds after the change.
    public static func isVisible(elapsed: TimeInterval, growth: CGFloat) -> Bool {
        elapsed > delay(forGrowth: growth)
    }
}

public struct VoiceBarNotchMotionStep: Equatable, Sendable {
    public let component: VoiceBarNotchMotionComponent
    public let targetVisible: Bool
    public let delay: TimeInterval
    public let duration: TimeInterval
    public let initialScale: CGFloat
    public let targetScale: CGFloat
    public let animation: VoiceBarNotchAnimationKind
}

public struct VoiceBarNotchMotionPlan: Equatable, Sendable {
    public let source: VoiceBarNotchVisualState
    public let destination: VoiceBarNotchVisualState
    public let steps: [VoiceBarNotchMotionStep]
    public let preservesFixedCore: Bool
    public let fixedCoreTranslation: CGPoint

    public var animatedComponents: Set<VoiceBarNotchMotionComponent> {
        Set(steps.map(\.component))
    }

    public static func resolve(
        from source: VoiceBarNotchVisualState,
        to destination: VoiceBarNotchVisualState,
        reducedMotion: Bool
    ) -> VoiceBarNotchMotionPlan {
        let steps: [VoiceBarNotchMotionStep] = if source == destination {
            []
        } else if surfaceExtent(destination) >= surfaceExtent(source) {
            openingSteps(reducedMotion: reducedMotion)
        } else {
            closingSteps(reducedMotion: reducedMotion)
        }

        return VoiceBarNotchMotionPlan(
            source: source,
            destination: destination,
            steps: steps,
            preservesFixedCore: true,
            fixedCoreTranslation: .zero
        )
    }

    private static func surfaceExtent(_ state: VoiceBarNotchVisualState) -> CGFloat {
        let geometry = VoiceBarNotchContract.geometry(for: state)
        return geometry.totalWidth * geometry.totalHeight
    }

    private static func openingSteps(reducedMotion: Bool) -> [VoiceBarNotchMotionStep] {
        let animation: VoiceBarNotchAnimationKind = reducedMotion ? .opacity : .spring
        let scales: [CGFloat] = reducedMotion ? [1, 1, 1] : [0.97, 0.985, 1]
        let panelDelay = VoiceBarNotchContract.motion.panelDelay

        return [
            step(
                component: .wings,
                visible: true,
                delay: 0,
                duration: 0.24,
                initialScale: scales[0],
                targetScale: 1,
                animation: animation
            ),
            step(
                component: .panel,
                visible: true,
                delay: panelDelay,
                duration: 0.26,
                initialScale: scales[1],
                targetScale: 1,
                animation: animation
            ),
            step(
                component: .content,
                visible: true,
                delay: panelDelay * 2,
                duration: 0.18,
                initialScale: scales[2],
                targetScale: 1,
                animation: animation
            ),
        ]
    }

    private static func closingSteps(reducedMotion: Bool) -> [VoiceBarNotchMotionStep] {
        let animation: VoiceBarNotchAnimationKind = reducedMotion ? .opacity : .spring
        let contentExit = VoiceBarNotchContract.motion.contentExitDuration
        let panelDelay = VoiceBarNotchContract.motion.panelDelay
        let targetScale: CGFloat = reducedMotion ? 1 : 0.97

        return [
            step(
                component: .content,
                visible: false,
                delay: 0,
                duration: contentExit,
                initialScale: 1,
                targetScale: reducedMotion ? 1 : 0.99,
                animation: animation
            ),
            step(
                component: .panel,
                visible: false,
                delay: contentExit,
                duration: 0.22,
                initialScale: 1,
                targetScale: targetScale,
                animation: animation
            ),
            step(
                component: .wings,
                visible: false,
                delay: contentExit + panelDelay,
                duration: 0.20,
                initialScale: 1,
                targetScale: targetScale,
                animation: animation
            ),
        ]
    }

    private static func step(
        component: VoiceBarNotchMotionComponent,
        visible: Bool,
        delay: TimeInterval,
        duration: TimeInterval,
        initialScale: CGFloat,
        targetScale: CGFloat,
        animation: VoiceBarNotchAnimationKind
    ) -> VoiceBarNotchMotionStep {
        VoiceBarNotchMotionStep(
            component: component,
            targetVisible: visible,
            delay: delay,
            duration: duration,
            initialScale: initialScale,
            targetScale: targetScale,
            animation: animation
        )
    }
}

public struct VoiceBarNotchActiveTransition: Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let plan: VoiceBarNotchMotionPlan
}

/// Visual-only replacement coordinator. A new target invalidates the prior
/// transition token while preserving one stable shell identity.
public struct VoiceBarNotchMotionCoordinator: Equatable, Sendable {
    public private(set) var targetState: VoiceBarNotchVisualState
    public private(set) var activeTransition: VoiceBarNotchActiveTransition?
    private var generation: UInt64

    public init(initialState: VoiceBarNotchVisualState) {
        targetState = initialState
        activeTransition = nil
        generation = 0
    }

    public var shellCount: Int {
        1
    }

    @discardableResult
    public mutating func replaceTarget(
        with destination: VoiceBarNotchVisualState,
        reducedMotion: Bool
    ) -> VoiceBarNotchActiveTransition {
        generation &+= 1
        let transition = VoiceBarNotchActiveTransition(
            id: generation,
            plan: VoiceBarNotchMotionPlan.resolve(
                from: targetState,
                to: destination,
                reducedMotion: reducedMotion
            )
        )
        targetState = destination
        activeTransition = transition
        return transition
    }
}
