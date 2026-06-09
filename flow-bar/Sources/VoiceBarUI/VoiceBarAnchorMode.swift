import CoreGraphics

public enum VoiceBarAnchorMode: String, CaseIterable, Identifiable {
    case follow
    case bottomCenter
    case topCenter

    public var id: String {
        rawValue
    }

    public static let anchorMenuModes: [VoiceBarAnchorMode] = [
        .follow,
        .topCenter,
    ]

    public static let anchoredPositionModes: [VoiceBarAnchorMode] = [
        .topCenter,
    ]

    public init(defaultsValue: String?) {
        let mode = defaultsValue.flatMap(Self.init(rawValue:)) ?? .follow
        self = mode == .bottomCenter ? .topCenter : mode
    }

    public var displayName: String {
        switch self {
        case .follow: "Follow Mouse"
        case .bottomCenter: "Notch Center"
        case .topCenter: "Notch Center"
        }
    }

    public var anchorMenuTitle: String {
        switch self {
        case .follow: "Off"
        case .bottomCenter: "Notch Center"
        case .topCenter: "Notch Center"
        }
    }

    public var allowsFreeDrag: Bool {
        self == .follow
    }

    public func placement(
        visibleFrame: CGRect,
        pillSize: CGSize,
        bottomClearance: CGFloat = 24,
        topOverlap: CGFloat = Theme.topAnchorNotchOverlap
    ) -> VoiceBarAnchorPlacement {
        switch self {
        case .follow:
            VoiceBarAnchorPlacement(horizontalOffset: 0.5, verticalOffset: nil, followsMouse: true)
        case .topCenter, .bottomCenter:
            VoiceBarAnchorPlacement(
                horizontalOffset: 0.5,
                verticalOffset: Self.topNotchVerticalOffset(
                    visibleFrame: visibleFrame,
                    pillSize: pillSize,
                    topOverlap: topOverlap
                ),
                followsMouse: false
            )
        }
    }

    private static func topNotchVerticalOffset(
        visibleFrame: CGRect,
        pillSize: CGSize,
        topOverlap: CGFloat
    ) -> CGFloat {
        guard visibleFrame.height > 0 else { return 0.5 }
        let targetTopY = visibleFrame.maxY + max(0, topOverlap)
        let targetMidY = targetTopY - (pillSize.height / 2)
        return (targetMidY - visibleFrame.origin.y) / visibleFrame.height
    }
}

public struct VoiceBarAnchorPlacement: Equatable {
    public var horizontalOffset: CGFloat
    public var verticalOffset: CGFloat?
    public var followsMouse: Bool

    public init(horizontalOffset: CGFloat, verticalOffset: CGFloat?, followsMouse: Bool) {
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.followsMouse = followsMouse
    }
}
