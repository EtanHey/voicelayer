import SwiftUI

/// "Checked ✓ just now · …" with its relative time kept current. It owns its own clock so the tick
/// re-renders only this line, never the whole Settings window (the rule SettingsPlaybackScrubBar follows;
/// SettingsPlaybackScrubBarTests pins that SettingsView.swift has no TimelineView).
struct SettingsShortcutCheckLine: View {
    let message: String
    let checkedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(SettingsShortcutCheck.feedback(message: message, checkedAt: checkedAt, now: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
