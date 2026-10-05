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
        let fields = [
            "panelVisible": String(panel?.isVisible ?? false),
            "panelOnActiveSpace": String(panel?.isOnActiveSpace ?? false),
            "panelOcclusionVisible": String(panel?.occlusionState.contains(.visible) ?? false),
            "panelWindowNumber": panel.map { String($0.windowNumber) } ?? "nil",
        ]
        return Dictionary(uniqueKeysWithValues: fields.map { key, value in
            (prefix.isEmpty ? key : prefix + key.prefix(1).uppercased() + key.dropFirst(), value)
        })
    }

    static func finishHandoffCollapse(isCancelled: Bool, mode: () -> VoiceMode,
                                      refreshLayout: () -> Void, orderOut: () -> Void) {
        guard !isCancelled, mode() == .idle else { return }
        refreshLayout()
        // Layout callbacks may re-enter mode handling; do not hide the new activity.
        guard mode() == .idle else { return }
        orderOut()
    }
}
