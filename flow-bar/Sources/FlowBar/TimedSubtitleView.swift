// TimedSubtitleView.swift — Word-synced subtitles for TTS playback.
//
// Displays words progressively as they're spoken, using exact timing
// from edge-tts WordBoundary metadata. Words are revealed by the
// VoiceState subtitle timer (driven by offset_ms from the server).
//
// Shows only the last few visible words, centered in the pill.

import SwiftUI

struct TimedSubtitleView: View {
    let words: [String]
    let visibleCount: Int

    /// Max words to show at once — older words fade out.
    private static let windowSize = 6

    /// The visible text string (last N words).
    private var visibleText: String {
        guard visibleCount > 0 else { return "" }
        let visible = Array(words.prefix(visibleCount))
        let window = visible.suffix(Self.windowSize)
        return window.joined(separator: " ")
    }

    var body: some View {
        Text(visibleText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .contentTransition(.interpolate)
            .animation(.easeOut(duration: 0.15), value: visibleCount)
    }
}
