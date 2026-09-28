import AppKit
import SwiftUI

/// Close and reopen for the reused Settings window (P09b follow-up 3, R1).
///
/// AIDEV-NOTE: The app keeps one Settings NSWindow (`isReleasedWhenClosed = false`), so closing it only hides
/// it: SwiftUI never runs onDisappear, and the hidden History/Ask views keep `.onReceive(
/// .voiceBarHistoryArchiveDidChange)`. Each dictation would then reload a page through the index and refill it
/// with Settings closed. Closing therefore drops the hosting controller FIRST (the views go away and cancel
/// their loads), THEN releases the index. Reopen rebuilds the hosting controller.
public enum SettingsWindowLifecycle {
    @MainActor
    public static func settingsWindowWillClose(
        _ window: NSWindow,
        index: SettingsArchiveIndex = .shared
    ) async {
        window.contentViewController = nil
        await index.release()
    }

    /// Puts a fresh SettingsView back into a window that was closed, keeping the size the user left it at
    /// (assigning a content view controller resizes the window to the view's fitting size). Returns whether it
    /// rebuilt.
    @MainActor
    @discardableResult
    public static func rebuildContentIfNeeded(
        _ window: NSWindow,
        makeSettingsView: () -> SettingsView
    ) -> Bool {
        guard window.contentViewController == nil else { return false }
        let frame = window.frame
        window.contentViewController = NSHostingController(rootView: makeSettingsView())
        window.setFrame(frame, display: false)
        return true
    }
}
