import SwiftUI

/// Reuses History's clock labels, drag preview, keyboard steps and VoiceOver adjustment.
/// This leaf samples F's clock at 4 Hz; the parent and word timeline never acquire a timer.
struct TeleprompterPlaybackScrubBar: View {
    let state: VoiceState

    var timingNotice: String? {
        let words = TeleprompterContentModel.words(text: state.statusText, wordBoundaries: state.wordBoundaries)
        return state.isTeleprompterPlaybackReady && !words.contains {
            TeleprompterSeekPolicy.offset(for: $0, isReadback: false) != nil
        } ? "Word timing unavailable" : nil
    }

    var control: SettingsPlaybackScrubBar {
        // An ended read seeks (SEEK2 readback scope) but has no running clock to sample.
        let playing = state.isTeleprompterPlaybackReady
        return SettingsPlaybackScrubBar(
            position: { state.teleprompterPlaybackPosition },
            seek: { seconds in state.seek(offsetMs: Int((seconds * 1000).rounded())) },
            accessibilityNoun: "agent speech",
            isPlaying: playing,
            isGrowing: playing && state.isPlaybackDurationGrowing,
            allowsSeeking: state.isTeleprompterScrubSeekable,
            isTeleprompter: true
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            control.disabled(!state.isTeleprompterScrubSeekable)
            if let timingNotice {
                Text(timingNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 154/255, green: 154/255, blue: 163/255))
            }
        }
    }
}
