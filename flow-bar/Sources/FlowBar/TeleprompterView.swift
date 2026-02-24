// TeleprompterView.swift — Word-by-word speaking text with karaoke highlighting.
//
// Multi-line wrapping layout with per-word styling. Current word is bright white,
// past words fade, upcoming words are dimmed. Auto-scrolls vertically to keep
// the current word visible. Uses FlowLayout for natural word wrapping.
//
// AIDEV-NOTE: Word timing is estimated, not synced to actual TTS audio.
// True sync would require word-level timestamps from the TTS engine.

import SwiftUI

// MARK: - Flow Layout (wrapping words across lines)

struct FlowLayout: Layout {
    var spacing: CGFloat = 5

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
        let maxWidth = proposal.width ?? .infinity
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
            ScrollView(.vertical, showsIndicators: false) {
                FlowLayout(spacing: 5) {
                    ForEach(0 ..< words.count, id: \.self) { index in
                        Text(words[index])
                            .font(.system(
                                size: 11,
                                weight: index == currentIndex ? .bold : .medium
                            ))
                            .foregroundStyle(
                                .white.opacity(opacityFor(index))
                            )
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollDisabled(true) // We control scroll position
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 8)
                Color.white
                LinearGradient(
                    colors: [.white, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 8)
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
