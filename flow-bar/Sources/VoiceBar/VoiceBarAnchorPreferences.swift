import Foundation
import VoiceBarUI

struct VoiceBarAnchorPreferences {
    static let anchorModeKey = "VoiceBar.anchorMode"
    static let positionLockedKey = "VoiceBar.positionLocked"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAnchorMode() -> VoiceBarAnchorMode {
        let storedValue = defaults.string(forKey: Self.anchorModeKey)
        let mode = VoiceBarAnchorMode(defaultsValue: storedValue)
        removeLegacyPositionLock()
        if storedValue != mode.rawValue {
            defaults.set(mode.rawValue, forKey: Self.anchorModeKey)
        }
        return mode
    }

    func saveAnchorMode(_ mode: VoiceBarAnchorMode) {
        defaults.set(mode.rawValue, forKey: Self.anchorModeKey)
        removeLegacyPositionLock()
    }

    private func removeLegacyPositionLock() {
        if defaults.object(forKey: Self.positionLockedKey) != nil {
            defaults.removeObject(forKey: Self.positionLockedKey)
        }
    }
}
