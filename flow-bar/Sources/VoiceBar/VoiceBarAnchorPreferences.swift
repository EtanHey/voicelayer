import Foundation
import VoiceBarUI

struct VoiceBarAnchorPreferences {
    static let anchorModeKey = "VoiceBar.anchorMode"
    static let positionLockedKey = "VoiceBar.positionLocked"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // AIDEV-NOTE: Anchor is removed from every menu (Etan ruling 1, 2026-09-24). A saved anchored mode
    // would strand the pill where no control can move it, so loading always resolves to `.follow` and
    // forgets what was stored.
    func loadAnchorMode() -> VoiceBarAnchorMode {
        defaults.removeObject(forKey: Self.anchorModeKey)
        removeLegacyPositionLock()
        return .follow
    }

    private func removeLegacyPositionLock() {
        if defaults.object(forKey: Self.positionLockedKey) != nil {
            defaults.removeObject(forKey: Self.positionLockedKey)
        }
    }
}
