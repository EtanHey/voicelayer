import Foundation

public enum VoiceBarHoverHysteresisEffect: Equatable, Sendable {
    case hoverChanged(Bool)
    case scheduleExit(after: TimeInterval)
    case cancelExit
}

/// Keeps the product's exact rendered path as the expand target while giving
/// an already-open surface a larger, forgiving collapse-out target.
///
/// This state machine is deliberately independent of VoiceState and audio.
/// Only pointer geometry can drive it.
public struct VoiceBarHoverHysteresis: Equatable, Sendable {
    public static let exitDelay: TimeInterval = 2.5

    public private(set) var isHovering = false
    private var isInsideExpansionZone = false
    private var isInsideRetentionZone = false
    private var hasPendingExit = false

    public init() {}

    public mutating func update(
        isInsideExpansionZone: Bool,
        isInsideRetentionZone: Bool
    ) -> [VoiceBarHoverHysteresisEffect] {
        self.isInsideExpansionZone = isInsideExpansionZone
        self.isInsideRetentionZone = isInsideRetentionZone

        if isInsideExpansionZone {
            var effects: [VoiceBarHoverHysteresisEffect] = []
            if hasPendingExit {
                hasPendingExit = false
                effects.append(.cancelExit)
            }
            if !isHovering {
                isHovering = true
                effects.append(.hoverChanged(true))
            }
            return effects
        }

        if isInsideRetentionZone {
            guard hasPendingExit else { return [] }
            hasPendingExit = false
            return [.cancelExit]
        }

        guard isHovering, !hasPendingExit else { return [] }
        hasPendingExit = true
        return [.scheduleExit(after: Self.exitDelay)]
    }

    public mutating func exitDelayElapsed() -> [VoiceBarHoverHysteresisEffect] {
        guard hasPendingExit else { return [] }
        hasPendingExit = false
        guard isHovering, !isInsideExpansionZone, !isInsideRetentionZone else {
            return []
        }
        isHovering = false
        return [.hoverChanged(false)]
    }
}
