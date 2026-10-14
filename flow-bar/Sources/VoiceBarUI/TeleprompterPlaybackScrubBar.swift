import SwiftUI

/// Reuses History's clock labels, drag preview, keyboard steps and VoiceOver adjustment.
/// This leaf samples F's clock at 4 Hz; the parent and word timeline never acquire a timer.
struct TeleprompterPlaybackScrubBar: View {
    let state: VoiceState

    var body: some View {
        SettingsPlaybackScrubBar(
            position: { state.teleprompterPlaybackPosition },
            seek: { seconds in state.seek(offsetMs: Int((seconds * 1000).rounded())) },
            accessibilityNoun: "agent speech",
            isPlaying: state.isTeleprompterPlaybackReady,
            isGrowing: state.isPlaybackDurationGrowing
        )
        .disabled(!state.isTeleprompterPlaybackReady)
    }
}
