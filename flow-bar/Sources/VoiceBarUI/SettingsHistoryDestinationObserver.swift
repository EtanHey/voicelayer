import SwiftUI

/// Observes the Settings consumer's actual scroll command; no transcript text is exposed.
struct SettingsHistoryDestinationObserverKey: EnvironmentKey {
    static let defaultValue: ((SettingsHistoryScope, String) -> Void)? = nil
}
extension EnvironmentValues {
    var settingsHistoryDestinationObserver: ((SettingsHistoryScope, String) -> Void)? {
        get { self[SettingsHistoryDestinationObserverKey.self] }
        set { self[SettingsHistoryDestinationObserverKey.self] = newValue }
    }
}
