import AppKit
import VoiceBarUI

enum NotchPanelVisibility {
    static func selfHeal(_ panel: NSWindow, mode: VoiceMode, isHidden: Bool,
                         log: ([String: String]) -> Void) {
        guard !isHidden, [.recording, .transcribing, .speaking].contains(mode),
              panel.isVisible,
              !panel.isOnActiveSpace || !panel.occlusionState.contains(.visible) else { return }
        let before = diagnosticFields(panel, prefix: "before")
        panel.orderFrontRegardless()
        log(before.merging(diagnosticFields(panel, prefix: "after")) { _, new in new })
    }

    static func diagnosticFields(_ panel: NSWindow?, prefix: String = "") -> [String: String] {
        let key = prefix.isEmpty ? "panel" : prefix + "Panel"
        return [
            "\(key)Visible": String(panel?.isVisible ?? false),
            "\(key)OnActiveSpace": String(panel?.isOnActiveSpace ?? false),
            "\(key)OcclusionVisible": String(panel?.occlusionState.contains(.visible) ?? false),
            "\(key)WindowNumber": panel.map { String($0.windowNumber) } ?? "nil",
        ]
    }

    static func finishHandoffCollapse(isCancelled: Bool, mode: () -> VoiceMode,
                                      refreshLayout: () -> Void, orderOut: () -> Void) {
        guard !isCancelled, mode() == .idle else { return }
        refreshLayout() // Callbacks may re-enter mode handling; do not hide the new activity.
        guard mode() == .idle else { return }
        orderOut()
    }
}
