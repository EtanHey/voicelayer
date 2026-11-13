import SwiftUI

/// Reuses History's clock labels, drag preview, keyboard steps and VoiceOver adjustment.
/// This leaf samples F's clock at 4 Hz; the parent and word timeline never acquire a timer.
struct TeleprompterPlaybackScrubBar: View {
    let state: VoiceState
    /// T8 (Etan QA 2026-11-09): the notch draws the timing notice in the eye row instead, so it never pushes the eye
    /// row away from the scrubber.
    var drawsTimingNotice = true

    func drawingTimingNotice(_ draws: Bool) -> Self {
        var copy = self
        copy.drawsTimingNotice = draws
        return copy
    }

    var timingNotice: String? {
        guard state.isTeleprompterPlaybackReady else { return nil }
        let text = state.teleprompterText ?? ""
        let hasTiming: Bool
        if let table = state.currentSpeechTiming, !table.words.isEmpty {
            let tokens = TeleprompterContentModel.displayTokens(text)
            hasTiming = table.words.enumerated().contains { index, word in
                guard let word, tokens.indices.contains(index) else { return false }
                return word.text == tokens[index]
            }
        } else {
            // An empty table is the placeholder before any speech_words event arrives.
            let words = TeleprompterContentModel.words(text: text, wordBoundaries: state.teleprompterWordBoundaries)
            hasTiming = TeleprompterPlaybackPolicy.usesServerTimestamps(in: words)
        }
        return hasTiming ? nil : "Word timing unavailable"
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
            isTeleprompter: true,
            disabledReason: Self.disabledReason(isPaused: state.isPlaybackPaused)
        )
    }

    static let pausedReason = "Paused. Press Play to seek"

    /// Hunt C5 teleprompter #3: X1-34 keeps the scrubber on screen while paused. A paused read refuses seeks (the
    /// paused-slider gate), and it says that, not "No word timing available".
    static func disabledReason(isPaused: Bool) -> String? {
        isPaused ? pausedReason : nil
    }

    /// R883 P2: the one line the notch draws under the scrubber. The frozen slider is disabled and SwiftUI `.help`
    /// never shows in the non-activating panel, so the pause reason is drawn, not hovered. While paused it outranks
    /// the timing warning (no seek works then anyway); after Play the timing warning returns.
    var notice: String? {
        Self.disabledReason(isPaused: state.isPlaybackPaused) ?? timingNotice
    }

    var body: some View {
        VStack(spacing: 3) {
            control.disabled(!state.isTeleprompterScrubSeekable)
            if drawsTimingNotice, let notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 154/255, green: 154/255, blue: 163/255))
            }
        }
    }
}
