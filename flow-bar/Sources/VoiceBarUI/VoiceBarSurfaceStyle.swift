public enum VoiceBarSurfaceStyle: Equatable {
    case floatingPill
    case menuBarIsland
    case v5Island
}

public extension VoiceBarSurfaceStyle {
    static func resolved(anchorMode: VoiceBarAnchorMode, v5Enabled: Bool) -> VoiceBarSurfaceStyle {
        if v5Enabled {
            return anchorMode == .topCenter ? .v5Island : .floatingPill
        }
        switch anchorMode {
        case .topCenter:
            return .menuBarIsland
        case .bottomCenter, .follow:
            return .floatingPill
        }
    }
}
