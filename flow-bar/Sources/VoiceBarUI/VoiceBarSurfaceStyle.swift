public enum VoiceBarSurfaceStyle: Equatable {
    case floatingPill
    case menuBarIsland
    case v5Island
}

public extension VoiceBarSurfaceStyle {
    static func resolved(anchorMode: VoiceBarAnchorMode, v5Enabled: Bool) -> VoiceBarSurfaceStyle {
        switch anchorMode {
        case .topCenter:
            v5Enabled ? .v5Island : .menuBarIsland
        case .bottomCenter, .follow:
            .floatingPill
        }
    }
}
