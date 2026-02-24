// TeleprompterView.swift — Word-by-word speaking text with karaoke highlighting.
//
// Smooth horizontal scroll through all words. Current word is bright white,
// past words fade, upcoming words are dimmed. ScrollViewReader handles
// smooth centering — no layout shift.
//
// AIDEV-NOTE: Word timing is estimated, not synced to actual TTS audio.
// True sync would require word-level timestamps from the TTS engine.

import SwiftUI

struct TeleprompterView: View {
    let text: String

    /// Base delay per word in seconds — adjusted by character count.
    private static let baseDelay: Double = 0.25
    private static let perCharDelay: Double = 0.05
    private static let minDelay: Double = 0.2
    private static let maxDelay: Double = 0.55

    @State private var currentIndex: Int = 0
    @State private var animationTask: Task<Void, Never>?

    private var words: [String] {
        text.split(separator: " ").map(String.init)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(0 ..< words.count, id: \.self) { index in
                        Text(words[index])
                            .font(.system(size: 11, weight: index == currentIndex ? .bold : .medium))
                            .foregroundStyle(.white.opacity(opacityFor(index)))
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollDisabled(true) // User can't scroll — we control position
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .white],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 12)
                Color.white
                LinearGradient(
                    colors: [.white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 12)
            }
        }
        .frame(maxWidth: 220)
        .onAppear { startAnimating() }
        .onDisappear { stopAnimating() }
        .onChange(of: text) { _, _ in restart() }
    }

    // MARK: - Word opacity

    private func opacityFor(_ index: Int) -> Double {
        if index == currentIndex { return 1.0 }
        if index < currentIndex {
            let distance = currentIndex - index
            return max(0.2, 0.55 - Double(distance) * 0.12)
        }
        return 0.3
    }

    // MARK: - Animation

    private func startAnimating() {
        guard words.count > 1 else { return }
        animationTask = Task { @MainActor in
            for i in 0 ..< words.count {
                currentIndex = i
                let word = words[i]
                let delay = Self.estimateDelay(for: word)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
            }
        }
    }

    /// Estimate speaking duration for a word based on length and punctuation.
    private static func estimateDelay(for word: String) -> Double {
        let charTime = baseDelay + Double(word.count) * perCharDelay
        var delay = min(maxDelay, max(minDelay, charTime))

        // Punctuation pauses — commas/semicolons add a short pause, periods/questions longer
        if let last = word.last {
            if last == "." || last == "!" || last == "?" {
                delay += 0.15
            } else if last == "," || last == ";" || last == ":" {
                delay += 0.08
            }
        }
        return delay
    }

    private func stopAnimating() {
        animationTask?.cancel()
        animationTask = nil
    }

    private func restart() {
        stopAnimating()
        currentIndex = 0
        startAnimating()
    }
}
