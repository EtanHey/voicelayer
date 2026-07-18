// TeleprompterView.swift — Word-by-word speaking text with karaoke highlighting.
//
// Multi-line wrapping layout with per-word styling. Current word is bright white,
// past words fade, upcoming words are dimmed. Uses server-provided WordBoundary
// timestamps when available, falls back to client-side estimation.

import SwiftUI

// MARK: - Flow Layout (wrapping words across lines)

public struct FlowLayout: Layout {
    public var spacing: CGFloat = 5
    /// Hard max width for word wrapping — needed because .fixedSize() on the
    /// parent passes nil proposal, which would collapse everything to one line.
    public var maxWidth: CGFloat = .infinity

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    public func placeSubviews(
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

public struct TeleprompterBoundary: Equatable {
    public let offsetMs: Int
    public let durationMs: Int
    public let text: String
}

public struct TeleprompterWord: Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let offsetMs: Int?
    public let durationMs: Int?
}

public enum TeleprompterPacePolicy {
    private static let baseDelay = 0.28
    private static let perCharacterDelay = 0.015
    private static let minimumDelay = 0.22
    private static let maximumDelay = 0.38

    public static func estimatedDelay(for word: String) -> Double {
        let characterDelay = baseDelay + Double(word.count) * perCharacterDelay
        var delay = min(maximumDelay, max(minimumDelay, characterDelay))

        if let last = word.last {
            if last == "." || last == "!" || last == "?" {
                delay += 0.10
            } else if last == "," || last == ";" || last == ":" {
                delay += 0.05
            }
        }
        return delay
    }

    public static func reschedule(
        displayWords: [TeleprompterWord],
        across boundaryWords: [TeleprompterWord]
    ) -> [TeleprompterWord] {
        guard !displayWords.isEmpty,
              let startOffset = boundaryWords.compactMap(\.offsetMs).min(),
              let endOffset = boundaryWords.compactMap({ word -> Int? in
                  guard let offset = word.offsetMs, let duration = word.durationMs else { return nil }
                  return offset + duration
              }).max(),
              endOffset > startOffset
        else { return displayWords }

        let weights = displayWords.map { estimatedDelay(for: $0.text) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return displayWords }

        let span = Double(endOffset - startOffset)
        var cumulativeWeight = 0.0
        return zip(displayWords, weights).enumerated().map { index, pair in
            let (word, weight) = pair
            let scheduledStart = startOffset + Int((span * cumulativeWeight / totalWeight).rounded())
            cumulativeWeight += weight
            let scheduledEnd = index == displayWords.indices.last
                ? endOffset
                : startOffset + Int((span * cumulativeWeight / totalWeight).rounded())
            return TeleprompterWord(
                id: word.id,
                text: word.text,
                offsetMs: scheduledStart,
                durationMs: max(1, scheduledEnd - scheduledStart)
            )
        }
    }
}

public enum TeleprompterContentModel {
    public static let maxDisplayTokenLength = 24
    private static let maximumBoundaryComparisonCharacters = 512

    public static func words(
        text: String,
        wordBoundaries: [TeleprompterBoundary]
    ) -> [TeleprompterWord] {
        let textWords = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                TeleprompterWord(
                    id: 0,
                    text: String(word),
                    offsetMs: nil,
                    durationMs: nil
                )
            }
            .flatMap(splitDisplayToken)
        let boundaryWords = wordBoundaries
            .map { boundary in
                TeleprompterWord(
                    id: 0,
                    text: boundary.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    offsetMs: boundary.offsetMs,
                    durationMs: boundary.durationMs
                )
            }
            .filter { !$0.text.isEmpty }
        let boundariesAreCurrent = boundariesPlausiblyBelong(
            to: textWords,
            boundaryWords: boundaryWords
        )

        if !textWords.isEmpty,
           textWords.count == boundaryWords.count,
           boundariesAreCurrent {
            return assignStableIDs(to: zip(textWords, boundaryWords).map { display, boundary in
                TeleprompterWord(
                    id: 0,
                    text: display.text,
                    offsetMs: boundary.offsetMs,
                    durationMs: boundary.durationMs
                )
            })
        }
        if !textWords.isEmpty {
            guard boundariesAreCurrent else {
                return assignStableIDs(to: textWords)
            }
            return assignStableIDs(
                to: TeleprompterPacePolicy.reschedule(
                    displayWords: textWords,
                    across: boundaryWords
                )
            )
        }
        if !boundaryWords.isEmpty {
            return assignStableIDs(to: boundaryWords.flatMap(splitDisplayToken))
        }
        return assignStableIDs(to: textWords)
    }

    private static func boundariesPlausiblyBelong(
        to displayWords: [TeleprompterWord],
        boundaryWords: [TeleprompterWord]
    ) -> Bool {
        guard !displayWords.isEmpty, !boundaryWords.isEmpty else { return false }
        let displayText = normalizedText(for: displayWords)
        let boundaryText = normalizedText(for: boundaryWords)
        guard !displayText.isEmpty, !boundaryText.isEmpty else { return false }
        guard displayText == boundaryText ||
            (!displayText.contains(boundaryText) && !boundaryText.contains(displayText))
        else {
            return false
        }
        let displaySignature = normalizedSignature(for: displayWords)
        let boundarySignature = normalizedSignature(for: boundaryWords)

        let maximumLength = max(displaySignature.count, boundarySignature.count)
        let distance = editDistance(displaySignature, boundarySignature)
        let similarity = 1 - (Double(distance) / Double(maximumLength))
        return similarity >= 0.55
    }

    private static func normalizedText(for words: [TeleprompterWord]) -> String {
        words
            .map(\.text)
            .joined()
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedSignature(for words: [TeleprompterWord]) -> [Character] {
        let signature = Array(normalizedText(for: words))
        guard signature.count > maximumBoundaryComparisonCharacters else {
            return signature
        }

        let lastSignatureIndex = signature.count - 1
        let lastSampleIndex = maximumBoundaryComparisonCharacters - 1
        return (0 ..< maximumBoundaryComparisonCharacters).map { sampleIndex in
            signature[(sampleIndex * lastSignatureIndex) / lastSampleIndex]
        }
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0 ... rhs.count)
        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                current.append(
                    min(
                        current[rhsIndex] + 1,
                        previous[rhsIndex + 1] + 1,
                        previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func assignStableIDs(to words: [TeleprompterWord]) -> [TeleprompterWord] {
        words.enumerated().map { index, word in
            TeleprompterWord(
                id: index,
                text: word.text,
                offsetMs: word.offsetMs,
                durationMs: word.durationMs
            )
        }
    }

    private static func splitDisplayToken(_ word: TeleprompterWord) -> [TeleprompterWord] {
        guard word.text.count > maxDisplayTokenLength else { return [word] }
        var chunks: [TeleprompterWord] = []
        var start = word.text.startIndex
        while start < word.text.endIndex {
            let end = word.text.index(
                start,
                offsetBy: maxDisplayTokenLength,
                limitedBy: word.text.endIndex
            ) ?? word.text.endIndex
            chunks.append(
                TeleprompterWord(
                    id: 0,
                    text: String(word.text[start ..< end]),
                    offsetMs: word.offsetMs,
                    durationMs: word.durationMs
                )
            )
            start = end
        }
        return chunks
    }
}

public enum TeleprompterScrollPosition: Equatable {
    case top
    case center
}

public enum TeleprompterScrollPolicy {
    public static let initialViewportAlignment: Alignment = .top

    public static func position(for wordIndex: Int) -> TeleprompterScrollPosition {
        wordIndex == 0 ? .top : .center
    }

    /// Replacing the brief must replace the ScrollView identity too. Otherwise
    /// SwiftUI can paint the previous brief's mid-stream offset for one frame
    /// before the onChange reset reaches word zero.
    public static func contentIdentity(for text: String) -> String {
        text
    }
}

public enum TeleprompterVisibilityPolicy {
    /// Hide/show is presentation-only: the mounted view owns the playback
    /// timeline, so removing it would restart highlighting from word zero.
    public static func keepsTimelineMounted(hasText: Bool) -> Bool {
        hasText
    }

    public static func timelineOpacity(isDismissed: Bool) -> Double {
        isDismissed ? 0 : 1
    }

    public static func hiddenLabelOpacity(isDismissed: Bool) -> Double {
        isDismissed ? 1 : 0
    }
}

public enum TeleprompterPlaybackPolicy {
    public static let startupDelay: Duration = .zero

    public static func animatesTimeline(isReadback: Bool) -> Bool {
        !isReadback
    }

    /// Live playback owns its karaoke opacity curve. Read-back is deliberately
    /// uniform so every original-script word remains equally legible.
    public static func wordOpacity(isReadback: Bool) -> Double? {
        isReadback ? 0.9 : nil
    }

    public static func showsScrollIndicators(isReadback: Bool) -> Bool {
        isReadback
    }
}

public struct TeleprompterView: View {
    public let text: String
    /// Server-provided word boundary timestamps (ms offsets from audio start).
    public var wordBoundaries: [(offsetMs: Int, durationMs: Int, text: String)] = []
    public var isReadback = false

    private static let scrollAnimation: Animation = .smooth(duration: 0.18)

    @State private var currentIndex: Int = 0
    @State private var animationTask: Task<Void, Never>?

    private var teleprompterWords: [TeleprompterWord] {
        TeleprompterContentModel.words(
            text: text,
            wordBoundaries: wordBoundaries.map {
                TeleprompterBoundary(
                    offsetMs: $0.offsetMs,
                    durationMs: $0.durationMs,
                    text: $0.text
                )
            }
        )
    }

    private var timedWords: [TeleprompterWord] {
        teleprompterWords.filter { $0.offsetMs != nil }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(
                .vertical,
                showsIndicators: TeleprompterPlaybackPolicy.showsScrollIndicators(
                    isReadback: isReadback
                )
            ) {
                FlowLayout(spacing: 5, maxWidth: Theme.teleprompterWrapWidth) {
                    wordViews
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, Theme.teleprompterContentInset)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Theme.teleprompterViewportHeight,
                    alignment: TeleprompterScrollPolicy.initialViewportAlignment
                )
            }
            .id(TeleprompterScrollPolicy.contentIdentity(for: text))
            .clipped()
            .onAppear {
                scrollToCurrentWord(with: proxy, animated: false)
                if TeleprompterPlaybackPolicy.animatesTimeline(isReadback: isReadback) {
                    startAnimating()
                }
            }
            .onDisappear { stopAnimating() }
            .onChange(of: text) { _, _ in
                restart()
                scrollToCurrentWord(with: proxy, animated: false)
            }
            .onChange(of: wordBoundaries.count) { _, _ in
                restart()
                scrollToCurrentWord(with: proxy, animated: false)
            }
            .onChange(of: currentIndex) { _, _ in
                scrollToCurrentWord(with: proxy)
            }
            .onChange(of: isReadback) { _, readback in
                if readback {
                    stopAnimating()
                } else {
                    restart()
                }
            }
        }
    }

    private var wordViews: some View {
        ForEach(teleprompterWords) { word in
            Text(word.text)
                .font(.system(
                    size: 16,
                    weight: word.id == currentIndex ? .bold : .medium
                ))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.teleprompterWrapWidth, alignment: .leading)
                .foregroundStyle(
                    .white.opacity(opacityFor(word.id))
                )
                .id(word.id)
        }
    }

    // MARK: - Word opacity

    private func opacityFor(_ index: Int) -> Double {
        if let readbackOpacity = TeleprompterPlaybackPolicy.wordOpacity(isReadback: isReadback) {
            return readbackOpacity
        }
        if index == currentIndex { return 1.0 }
        if index < currentIndex {
            let distance = currentIndex - index
            return max(0.2, 0.55 - Double(distance) * 0.12)
        }
        return 0.3
    }

    // MARK: - Animation

    private var hasServerTimestamps: Bool {
        !timedWords.isEmpty
    }

    private func startAnimating() {
        guard TeleprompterPlaybackPolicy.animatesTimeline(isReadback: isReadback) else { return }
        guard teleprompterWords.count > 1 else { return }

        if hasServerTimestamps {
            startTimestampAnimation()
        } else {
            startEstimatedAnimation()
        }
    }

    /// Server-driven animation: use exact word boundary timestamps from edge-tts.
    /// Each word is highlighted at its exact offset_ms from audio start.
    private func startTimestampAnimation() {
        let words = timedWords

        animationTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterPlaybackPolicy.startupDelay)
            if Task.isCancelled { return }

            let startTime = ContinuousClock.now

            for word in words {
                guard let targetOffsetMs = word.offsetMs else { continue }
                // Calculate when this word should be highlighted
                let targetOffset = Duration.milliseconds(targetOffsetMs)
                let elapsed = ContinuousClock.now - startTime

                // Wait until the word's offset time
                if targetOffset > elapsed {
                    try? await Task.sleep(for: targetOffset - elapsed)
                }

                if Task.isCancelled { break }
                currentIndex = word.id
            }
        }
    }

    /// Client-side estimated animation (fallback for non-edge-tts engines).
    private func startEstimatedAnimation() {
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterPlaybackPolicy.startupDelay)
            if Task.isCancelled { return }
            for i in 0 ..< teleprompterWords.count {
                currentIndex = i
                let delay = TeleprompterPacePolicy.estimatedDelay(
                    for: teleprompterWords[i].text
                )
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
            }
        }
    }

    private func stopAnimating() {
        animationTask?.cancel()
        animationTask = nil
    }

    private func scrollToCurrentWord(
        with proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard teleprompterWords.indices.contains(currentIndex) else { return }

        let anchor: UnitPoint = switch TeleprompterScrollPolicy.position(for: currentIndex) {
        case .top: .top
        case .center: .center
        }
        if animated, currentIndex > 0 {
            withAnimation(Self.scrollAnimation) {
                proxy.scrollTo(currentIndex, anchor: anchor)
            }
        } else {
            proxy.scrollTo(currentIndex, anchor: anchor)
        }
    }

    private func restart() {
        stopAnimating()
        currentIndex = 0
        startAnimating()
    }
}
