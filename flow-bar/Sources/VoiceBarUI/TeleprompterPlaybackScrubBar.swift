import SwiftUI

/// Reuses History's clock labels, drag preview, keyboard steps and VoiceOver adjustment.
/// This leaf samples F's clock at 4 Hz; the parent and word timeline never acquire a timer.
struct TeleprompterPlaybackScrubBar: View {
    let state: VoiceState

    var control: SettingsPlaybackScrubBar {
        let interactive = state.isTeleprompterPlaybackReady
        return SettingsPlaybackScrubBar(
            position: { state.teleprompterPlaybackPosition },
            seek: { seconds in state.seek(offsetMs: Int((seconds * 1000).rounded())) },
            accessibilityNoun: "agent speech",
            isPlaying: interactive,
            isGrowing: interactive && state.isPlaybackDurationGrowing,
            allowsSeeking: interactive,
            isTeleprompter: true
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            control.disabled(!state.isTeleprompterPlaybackReady)
            if state.isTeleprompterPlaybackReady && state.wordBoundaries.isEmpty {
                Text("Cloned voice: no word timing")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 154/255, green: 154/255, blue: 163/255))
            }
        }
    }
}
