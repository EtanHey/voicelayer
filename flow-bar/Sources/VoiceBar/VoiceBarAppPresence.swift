import AppKit
import VoiceBarUI

/// 2.3 SPEC (d) / ruling M8: with the menu-bar item gone, VoiceBar stays findable, quittable and versioned through the
/// Dock, ⌘Tab and Force Quit. Pure decisions, so the launch path and the tests read the same rule.
enum VoiceBarAppPresence {
    /// The resident app is a regular app. An isolated dev/QA instance (socket override) stays an accessory, so a test
    /// build never puts a second VoiceBar in the Dock or ⌘Tab next to the real one. Info.plist keeps `LSUIElement`
    /// for the same reason: a QA bundle must not flash a Dock icon before this runs.
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

    /// A Dock click on the regular app brings back a hidden notch and opens Settings at General. This is the SPEC's
    /// recommendation for open question 3 (Settings vs the History window), still awaiting the ruling. Without a
    /// Dock icon a reopen comes from `open -a` or Finder and keeps today's behaviour: nothing opens.
    static func dockReopenPlan(policy: NSApplication.ActivationPolicy, isSnoozed: Bool) -> DockReopenPlan {
        guard policy == .regular else { return .none }
        return DockReopenPlan(unsnooze: isSnoozed, settingsTab: .general)
    }
}
