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
