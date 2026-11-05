import AppKit
import VoiceBarUI

/// SPEC (d): resident Dock presence and the Dock reopening decision.
enum VoiceBarAppPresence {
    /// QA stays accessory; Info.plist keeps LSUIElement to avoid a Dock flash before launch.
    static func activationPolicy(enforcesSingletonInstance: Bool) -> NSApplication.ActivationPolicy {
        enforcesSingletonInstance ? .regular : .accessory
    }

    /// Only the regular app has a Dock icon and the notch menu, so only it drops the status item down to the alert.
    static func statusItemIsAlertOnly(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policy == .regular
    }

    struct DockReopenPlan: Equatable {
        var unsnooze: Bool
        var settingsTab: SettingsTab?

        static let none = DockReopenPlan(unsnooze: false, settingsTab: nil)
    }

    /// SPEC open question 3 recommendation: restore the hidden notch and open General.
    static func dockReopenPlan(policy: NSApplication.ActivationPolicy, isSnoozed: Bool) -> DockReopenPlan {
        guard policy == .regular else { return .none }
        return DockReopenPlan(unsnooze: isSnoozed, settingsTab: .general)
    }
}
