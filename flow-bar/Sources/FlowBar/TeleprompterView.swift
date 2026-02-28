// TeleprompterView.swift — Word-by-word speaking text with karaoke highlighting.
//
// Multi-line wrapping layout with per-word styling. Current word is bright white,
// past words fade, upcoming words are dimmed. Uses server-provided WordBoundary
// timestamps when available, falls back to client-side estimation.

import SwiftUI

// MARK: - Flow Layout (wrapping words across lines)

struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    /// Hard max width for word wrapping — needed because .fixedSize() on the
    /// parent passes nil proposal, which would collapse everything to one line.
    var maxWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated()
            where index < subviews.count {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + position.x,
                    y: bounds.minY + position.y
                ),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = min(maxWidth, proposal.width ?? .infinity)
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing * 0.6
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x)
        }

        return (
            CGSize(width: maxX, height: y + lineHeight),
            positions
        )
    }
}

// MARK: - Teleprompter View

struct TeleprompterView: View {
    let text: String
    /// Server-provided word boundary timestamps (ms offsets from audio start).
    var wordBoundaries: [(offsetMs: Int, durationMs: Int, text: String)] = []

    /// Fallback timing constants for non-edge-tts engines (client estimation).
    private static let baseDelay: Double = 0.28
    private static let perCharDelay: Double = 0.015
    private static let minDelay: Double = 0.22
    private static let maxDelay: Double = 0.38

    @State private var currentIndex: Int = 0
    @State private var animationTask: Task<Void, Never>?

    private var words: [String] {
        text.split(separator: " ").map(String.init)
    }

    var body: some View {
        FlowLayout(spacing: 5, maxWidth: 280) {
            wordViews
        }
        .padding(.horizontal, 4)
        .onAppear { startAnimating() }
        .onDisappear { stopAnimating() }
        .onChange(of: text) { _, _ in restart() }
        .onChange(of: wordBoundaries.count) { _, newCount in
            if newCount > 0 { restart() }
        }
    }

    private var wordViews: some View {
        ForEach(0 ..< words.count, id: \.self) { index in
            Text(words[index])
                .font(.system(
                    size: 16,
                    weight: index == currentIndex ? .bold : .medium
                ))
                .foregroundStyle(
                    .white.opacity(opacityFor(index))
                )
                .id(index)
        }
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

    private var hasServerTimestamps: Bool {
        !wordBoundaries.isEmpty
    }

    private func startAnimating() {
        guard words.count > 1 else { return }

        if hasServerTimestamps {
            startTimestampAnimation()
        } else {
            startEstimatedAnimation()
        }
    }

    /// Server-driven animation: use exact word boundary timestamps from edge-tts.
    /// Each word is highlighted at its exact offset_ms from audio start.
    private func startTimestampAnimation() {
        let boundaries = wordBoundaries
        let wordCount = words.count

        animationTask = Task { @MainActor in
            // Wait for audio player to start (~300ms startup latency)
            try? await Task.sleep(for: .seconds(0.3))
            if Task.isCancelled { return }

            let startTime = ContinuousClock.now

            for i in 0 ..< min(wordCount, boundaries.count) {
                // Calculate when this word should be highlighted
                let targetOffset = Duration.milliseconds(boundaries[i].offsetMs)
                let elapsed = ContinuousClock.now - startTime

                // Wait until the word's offset time
                if targetOffset > elapsed {
                    try? await Task.sleep(for: targetOffset - elapsed)
                }

                if Task.isCancelled { break }
                currentIndex = i
            }

            // If there are more display words than boundaries (text was split
            // differently than TTS), advance through remaining words quickly
            if wordCount > boundaries.count {
                for i in boundaries.count ..< wordCount {
                    currentIndex = i
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { break }
                }
            }
        }
    }

    /// Client-side estimated animation (fallback for non-edge-tts engines).
    private func startEstimatedAnimation() {
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            if Task.isCancelled { return }
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

        if let last = word.last {
            if last == "." || last == "!" || last == "?" {
                delay += 0.10
            } else if last == "," || last == ";" || last == ":" {
                delay += 0.05
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
