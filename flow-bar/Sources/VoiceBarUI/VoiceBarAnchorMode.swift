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
        .bottomCenter,
    ]

    public static let anchoredPositionModes: [VoiceBarAnchorMode] = [
        .topCenter,
        .bottomCenter,
    ]

    public init(defaultsValue: String?) {
        self = defaultsValue.flatMap(Self.init(rawValue:)) ?? .follow
    }

    public var displayName: String {
        switch self {
        case .follow: "Follow Mouse"
        case .bottomCenter: "Bottom Center"
        case .topCenter: "Top Center"
        }
    }

    public var anchorMenuTitle: String {
        switch self {
        case .follow: "Off"
        case .bottomCenter: "Bottom Center"
        case .topCenter: "Top Center"
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
        case .topCenter:
            VoiceBarAnchorPlacement(horizontalOffset: 0.5, verticalOffset: nil, followsMouse: false)
        case .bottomCenter:
            VoiceBarAnchorPlacement(
                horizontalOffset: 0.5,
                verticalOffset: min(0.95, max(0, (bottomClearance + (pillSize.height / 2)) / visibleFrame.height)),
                followsMouse: false
            )
        }
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
