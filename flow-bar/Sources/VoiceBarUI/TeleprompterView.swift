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
        Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            items: subviews.map { $0[TeleprompterFlowItemKey.self] },
            maxWidth: min(maxWidth, proposal.width ?? .infinity),
            spacing: spacing
        )
    }

    /// TELE1: explicit line and paragraph breaks, list items whose wrapped lines hang under their text,
    /// and closing punctuation kept flush with its word. Default items wrap exactly as plain words.
    static func arrange(
        sizes: [CGSize], items: [TeleprompterFlowItem], maxWidth: CGFloat, spacing: CGFloat
    ) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        var indent: CGFloat = 0
        func item(_ index: Int) -> TeleprompterFlowItem {
            items.indices.contains(index) ? items[index] : TeleprompterFlowItem()
        }

        for (index, size) in sizes.enumerated() {
            let current = item(index)
            if index > 0, current.lineBreak != .none {
                x = 0
                indent = 0
                y += lineHeight + spacing * (current.lineBreak == .paragraph ? 1.8 : 0.6)
                lineHeight = 0
            } else if index > 0, current.gluesToPrevious {
                x -= spacing
            } else {
                var width = size.width
                var next = index + 1
                while next < sizes.count, item(next).gluesToPrevious {
                    width += sizes[next].width
                    next += 1
                }
                if x + width > maxWidth, x > indent {
                    x = indent
                    y += lineHeight + spacing * 0.6
                    lineHeight = 0
                }
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x)
            if current.isListMarker { indent = min(x, maxWidth / 3) }
        }

        return (
            CGSize(width: maxX, height: y + lineHeight),
            positions
        )
    }
}

// MARK: - Teleprompter View

public struct TeleprompterBoundary: Equatable {
    public let offsetMs: Int?
    public let durationMs: Int?
    public let text: String
    public let wordIndex: Int?
    /// WORDTIME1: estimated between measured neighbours, not measured itself.
    public let isInterpolated: Bool

    public init(offsetMs: Int?, durationMs: Int?, text: String, wordIndex: Int? = nil, isInterpolated: Bool = false) {
        self.offsetMs = offsetMs
        self.durationMs = durationMs
        self.text = text
        self.wordIndex = wordIndex
        self.isInterpolated = isInterpolated
    }

    /// Indexed rows by word_index, or nil when any row fails its token identity (the caller fails closed).
    static func indexedRows(_ rows: [Self], tokens: [String]) -> [Int: Self]? {
        var byIndex: [Int: Self] = [:]
        for row in rows {
            guard let index = row.wordIndex, tokens.indices.contains(index),
                  tokens[index] == row.text, byIndex[index] == nil else { return nil }
            byIndex[index] = row
        }
        return byIndex
    }

    /// WORDTIME1: clone timing leaves short and punctuation-glued tokens null. Each one gets an even
    /// share of the gap between its timed neighbours (decoded audio onset before the first, the chunk's
    /// audio end after the last), so every displayed word highlights and seeks. Offsets stay in token
    /// order; a gap with no room, or a tail with no known audio end, stays untimed.
    static func interpolated(_ rows: [Self], text: String, startMs: Int?, endMs: Int?) -> [Self] {
        let tokens = TeleprompterContentModel.displayTokens(text)
        guard rows.contains(where: { $0.wordIndex != nil }),
              let byIndex = indexedRows(rows, tokens: tokens) else { return rows }
        var result = tokens.indices.map { byIndex[$0] ?? Self(offsetMs: nil, durationMs: nil, text: tokens[$0], wordIndex: $0) }
        // Inspect source line position, not just the marker glyph: a + b is prose.
        let source = text as NSString
        let markerRanges = Set(try! NSRegularExpression(pattern: #"(?m)^[ \t]*([-+*•◦▪‣])(?=[ \t])"#)
            .matches(in: text, range: NSRange(location: 0, length: source.length)).map { $0.range(at: 1).location })
        var cursor = 0
        let markerIndices = Set(tokens.indices.filter { index in
            let range = source.range(of: tokens[index], range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { return false }
            cursor = NSMaxRange(range)
            return markerRanges.contains(range.location)
        })
        let timed = result.indices.filter { result[$0].offsetMs != nil }
        guard let first = timed.first, let last = timed.last else { return result }
        func end(_ index: Int) -> Int { result[index].offsetMs! + (result[index].durationMs ?? 0) }
        func fill(_ gap: Range<Int>, from: Int, to: Int) {
            guard !gap.isEmpty, to > from else { return }
            let span = Double(to - from), count = Double(gap.count)
            for (step, index) in gap.enumerated() {
                guard !markerIndices.contains(index) else { continue }
                let start = from + Int(span * Double(step) / count), stop = from + Int(span * Double(step + 1) / count)
                guard stop > start else { continue }
                result[index] = Self(offsetMs: start, durationMs: stop - start, text: tokens[index],
                                     wordIndex: index, isInterpolated: true)
            }
        }
        if let startMs { fill(0 ..< first, from: max(0, startMs), to: result[first].offsetMs!) }
        for (left, right) in zip(timed, timed.dropFirst()) where right > left + 1 {
            let next = result[right].offsetMs!
            // Overlapping neighbours: share the left word's window rather than tie with it.
            fill(left + 1 ..< right, from: end(left) < next ? end(left) : result[left].offsetMs! + 1, to: next)
        }
        if let endMs { fill(last + 1 ..< tokens.count, from: end(last), to: endMs) }
        return result
    }

    static func subtitleWords(_ event: [String: Any], chunkStartMs: Int) -> [Self] {
        let indexed = event["aligned_words"] != nil
        let rows = event[indexed ? "aligned_words" : "words"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let text = row["text"] as? String else {
                return indexed ? Self(offsetMs: nil, durationMs: nil, text: "", wordIndex: -1) : nil
            }
            // Match the old decoder's Int-first coercion (including JSON booleans)
            // and signed fractional truncation, without trapping on unsafe Doubles.
            func legacyMilliseconds(_ value: Any?) -> Int? {
                // JSON can retain an out-of-range integer as NSDecimalNumber;
                // converting it to Double first can round it back into Int's range.
                if let number = value as? NSDecimalNumber {
                    var original = number.decimalValue
                    guard !original.isNaN else { return nil }
                    var truncated = Decimal()
                    NSDecimalRound(&truncated, &original, 0, original < 0 ? .up : .down)
                    guard truncated >= Decimal(Int.min), truncated <= Decimal(Int.max) else { return nil }
                    return NSDecimalNumber(decimal: truncated).intValue
                }
                if let integer = value as? Int { return integer }
                guard let number = value as? Double, number.isFinite else { return nil }
                return Int(exactly: number.rounded(.towardZero))
            }
            // Indexed acoustic timings keep strict nonnegative, non-boolean validation.
            func milliseconds(_ value: Any?, integral: Bool = false) -> Int? {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0,
                      !integral || number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
                return Int(exactly: number.doubleValue.rounded(.towardZero))
            }
            let offset = indexed ? milliseconds(row["offset_ms"]) : legacyMilliseconds(row["offset_ms"])
            let duration = indexed ? milliseconds(row["duration_ms"]) : legacyMilliseconds(row["duration_ms"])
            let index = milliseconds(row["word_index"], integral: true)
            // WORDTIME1 history: an estimate or Edge seek anchor, which may be zero-length. Measured rows never are.
            let estimated = indexed && (row["estimated"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
            if !indexed, offset == nil || duration == nil { return nil }
            var globalOffset: Int?
            // Legacy values retain their signs and zero-duration markdown anchors.
            // Only indexed timing requires a nonnegative start and positive span.
            if let offset, let duration, (!indexed || (offset >= 0 && (duration > 0 || estimated) && chunkStartMs >= 0)) {
                let global = offset.addingReportingOverflow(chunkStartMs)
                if !global.overflow && !global.partialValue.addingReportingOverflow(duration).overflow {
                    globalOffset = global.partialValue
                }
            }
            // A legacy placeholder would enable estimated karaoke without timing.
            if !indexed, globalOffset == nil { return nil }
            return Self(offsetMs: globalOffset, durationMs: globalOffset == nil ? nil : duration,
                        text: text, wordIndex: indexed ? (index ?? -1) : nil, isInterpolated: estimated && globalOffset != nil)
        }
    }
}

public struct TeleprompterWord: Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let offsetMs: Int?
    public let durationMs: Int?
    /// Rescheduled display words can highlight, but their estimates are never seek targets.
    public var hasEstimatedTiming = false
    /// Only the indexed format opts into a measured-only partial timeline.
    public var usesIndexedTiming = false
    /// WORDTIME1: an indexed estimate between measured words. Unlike a reschedule, it seeks.
    public var hasInterpolatedTiming = false
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
                durationMs: max(1, scheduledEnd - scheduledStart),
                hasEstimatedTiming: true
            )
        }
    }
}

public enum TeleprompterContentModel {
    // Mirrors display-tokens.ts: prose alternatives, lexical paths/code, and chunk context resets.
    static func displayTokens(_ text: String) -> [String] {
        let source = text as NSString
        return displayTokenRanges(text).map { source.substring(with: $0) }
    }

    private static let proseSlashCuts = try! NSRegularExpression(pattern: #"https?://[^\s<>]+|www\.[^\s<>]+|(`+)(?!`)[^\u2029]*?(?<!`)\1(?!`)|\]\([^\n\u2029]*?\)|(?<![\p{L}\p{M}\p{N}\p{S}\p{Cf}_./\\:`~-])(?!(?:TCP/IP|he/she|assets/[A-Za-z]+)(?![A-Za-z]))[A-Za-z]{2,}/[A-Za-z]{2,}(?=(?:[.,;!?):\]"'’]*)(?:\s|$|,(?=[A-Za-z]{2,}/)))"#)
    private static let nonWhitespace = try! NSRegularExpression(pattern: #"\S+"#)

    /// UTF-16 ranges of `displayTokens`; structured-display word indices count these.
    /// One ordered pass: the decoder calls this on the main thread for whole long reads.
    static func displayTokenRanges(_ text: String) -> [NSRange] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        // Every cut is a prose slash, so text without one has none.
        let cuts = source.range(of: "/").location == NSNotFound ? [] : proseSlashCuts.matches(in: text, range: whole).compactMap { match -> Int? in
            let token = source.substring(with: match.range)
            guard !["http://", "https://", "www.", "`", "]("].contains(where: { token.hasPrefix($0) }) else { return nil }
            return match.range.location + (token as NSString).range(of: "/").location
        }
        // Matches arrive in source order, so one cursor pairs each word with its cuts.
        var ranges: [NSRange] = [], next = 0
        for match in nonWhitespace.matches(in: text, range: whole) {
            var start = match.range.location
            let end = NSMaxRange(match.range)
            while next < cuts.count, cuts[next] <= start { next += 1 }
            while next < cuts.count, cuts[next] < end {
                ranges.append(NSRange(location: start, length: cuts[next] - start))
                start = cuts[next]; next += 1
            }
            ranges.append(NSRange(location: start, length: end - start))
        }
        return ranges
    }

    public static let maxDisplayTokenLength = 24
    private static let maximumBoundaryComparisonCharacters = 512

    public static func words(
        text: String,
        wordBoundaries: [TeleprompterBoundary]
    ) -> [TeleprompterWord] {
        if wordBoundaries.contains(where: { $0.wordIndex != nil }) {
            let tokens = TeleprompterContentModel.displayTokens(text)
            guard let byIndex = TeleprompterBoundary.indexedRows(wordBoundaries, tokens: tokens) else {
                return words(text: text, wordBoundaries: [])
            }
            return assignStableIDs(to: tokens.enumerated().flatMap { index, token in
                let boundary = byIndex[index]
                return splitDisplayToken(TeleprompterWord(id: 0, text: token,
                    offsetMs: boundary?.offsetMs, durationMs: boundary?.durationMs, usesIndexedTiming: true,
                    hasInterpolatedTiming: boundary?.isInterpolated ?? false))
            })
        }
        let textWords = displayTokens(text)
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

    /// TELE1: legacy (Edge) rows, one per whitespace token, keyed by token index. Nil unless the counts
    /// match and the rows plausibly spell the text, the same test the per-chunk zip uses.
    static func legacyTokenRows(text: String, boundaries: [TeleprompterBoundary]) -> [Int: TeleprompterBoundary]? {
        let tokens = TeleprompterContentModel.displayTokens(text)
        let rows = boundaries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !tokens.isEmpty, rows.count == tokens.count, boundariesPlausiblyBelong(
            to: tokens.map { TeleprompterWord(id: 0, text: $0, offsetMs: nil, durationMs: nil) },
            boundaryWords: rows.map { TeleprompterWord(id: 0, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       offsetMs: $0.offsetMs, durationMs: $0.durationMs) }
        ) else { return nil }
        return Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.offset, $0.element) })
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
                durationMs: word.durationMs,
                hasEstimatedTiming: word.hasEstimatedTiming,
                usesIndexedTiming: word.usesIndexedTiming,
                hasInterpolatedTiming: word.hasInterpolatedTiming
            )
        }
    }

    /// How many display words `splitDisplayToken` makes of one whitespace token.
    static func displayPieceCount(_ token: String) -> Int {
        max(1, (token.count + maxDisplayTokenLength - 1) / maxDisplayTokenLength)
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
                    durationMs: word.durationMs,
                    hasEstimatedTiming: word.hasEstimatedTiming,
                    usesIndexedTiming: word.usesIndexedTiming,
                    hasInterpolatedTiming: word.hasInterpolatedTiming
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
    /// Short text sits centred in the fixed viewport; longer text still scrolls from word zero.
    public static let initialViewportAlignment: Alignment = .center

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
    public static func restartWordIndex(in words: [TeleprompterWord], elapsedMilliseconds: Int, isReadback: Bool) -> Int {
        isReadback ? 0 : currentWordIndex(in: words, elapsedMilliseconds: elapsedMilliseconds)
    }

    public static let startupDelay: Duration = .zero

    public static func currentWordIndex(
        in words: [TeleprompterWord],
        elapsedMilliseconds: Int
    ) -> Int {
        guard !words.isEmpty else { return 0 }
        let elapsedMilliseconds = max(0, elapsedMilliseconds)
        var currentWordID = -1
        for index in words.indices {
            guard let offset = playbackOffsetMilliseconds(forWordAt: index, in: words) else { continue }
            guard offset <= elapsedMilliseconds else {
                break
            }
            currentWordID = words[index].id
        }
        return currentWordID
    }

    public static func playbackOffsetMilliseconds(
        forWordAt index: Int,
        in words: [TeleprompterWord]
    ) -> Int? {
        guard words.indices.contains(index) else { return nil }
        if usesServerTimestamps(in: words) {
            return words[index].offsetMs
        }
        let seconds = words[..<index].reduce(0.0) { partialResult, word in
            partialResult + TeleprompterPacePolicy.estimatedDelay(for: word.text)
        }
        return Int((seconds * 1000).rounded())
    }

    public static func usesServerTimestamps(in words: [TeleprompterWord]) -> Bool {
        if words.contains(where: \.usesIndexedTiming) { return words.contains { $0.offsetMs != nil } }
        return !words.isEmpty && words.allSatisfy { $0.offsetMs != nil }
    }

    public static func animatesTimeline(isReadback: Bool) -> Bool {
        !isReadback
    }

    /// Live playback owns its karaoke opacity curve. Read-back is deliberately
    /// uniform so every original-script word remains equally legible.
    public static func wordOpacity(isReadback: Bool) -> Double? {
        isReadback ? 0.9 : nil
    }

    /// Never: with "Show scroll bars: Always", a legacy scroller's gutter re-centres readback text
    /// left of where it was spoken. Readback still scrolls by trackpad and wheel.
    public static func showsScrollIndicators(isReadback _: Bool) -> Bool {
        false
    }
}

public enum TeleprompterSeekPolicy {
    public static func offset(for word: TeleprompterWord, isReadback _: Bool) -> Int? {
        guard !word.hasEstimatedTiming, let offset = word.offsetMs, offset >= 0 else { return nil }
        return offset
    }

    public static func seek(_ word: TeleprompterWord, isReadback: Bool, seek: (Int) -> Void, unavailable: () -> Void = {}) {
        guard let offset = offset(for: word, isReadback: isReadback) else {
            if isReadback { unavailable() }
            return
        }
        seek(offset)
    }
}

/// Owns one cursor stack entry across word transitions; view/word teardown is idempotent.
struct TeleprompterPointerState {
    private var hoveredWords: Set<Int> = []

    mutating func hover(wordID: Int, isInside: Bool, push: () -> Void, pop: () -> Void) {
        let wasEmpty = hoveredWords.isEmpty
        if isInside { hoveredWords.insert(wordID) } else { hoveredWords.remove(wordID) }
        if wasEmpty && !hoveredWords.isEmpty { push() }
        if !wasEmpty && hoveredWords.isEmpty { pop() }
    }

    mutating func reset(pop: () -> Void) {
        if !hoveredWords.isEmpty { pop() }
        hoveredWords.removeAll()
    }
}

public struct TeleprompterView: View {
    public let text: String
    public var displayBlocks: [TeleprompterDisplayBlock] = []
    public var hasCompleteDisplay = false
    public var playbackEpoch = 0
    /// Server-provided word boundary timestamps (ms offsets from audio start).
    public var wordBoundaries: [TeleprompterBoundary] = []
    public var isReadback = false
    public let playbackElapsedMilliseconds: () -> Int
    public var onSeek: ((Int) -> Void)?
    public var onSeekUnavailable: (() -> Void)?
    public var estimatedPlaybackStartMilliseconds = 0
    public var wrapWidth = Theme.teleprompterWrapWidth
    public var viewportHeight = Theme.teleprompterViewportHeight
    public var contentInset = Theme.teleprompterContentInset

    public init(
        text: String,
        wordBoundaries: [TeleprompterBoundary] = [],
        displayBlocks: [TeleprompterDisplayBlock] = [],
        hasCompleteDisplay: Bool = false,
        isReadback: Bool = false,
        playbackEpoch: Int = 0,
        playbackElapsedMilliseconds: @escaping () -> Int,
        onSeek: ((Int) -> Void)? = nil,
        onSeekUnavailable: (() -> Void)? = nil,
        estimatedPlaybackStartMilliseconds: Int = 0,
        wrapWidth: CGFloat = Theme.teleprompterWrapWidth,
        viewportHeight: CGFloat = Theme.teleprompterViewportHeight,
        contentInset: CGFloat = Theme.teleprompterContentInset
    ) {
        self.text = text
        self.displayBlocks = displayBlocks
        self.hasCompleteDisplay = hasCompleteDisplay
        self.wordBoundaries = wordBoundaries
        self.isReadback = isReadback
        self.playbackEpoch = playbackEpoch
        self.playbackElapsedMilliseconds = playbackElapsedMilliseconds
        self.onSeek = onSeek
        self.onSeekUnavailable = onSeekUnavailable
        self.estimatedPlaybackStartMilliseconds = estimatedPlaybackStartMilliseconds
        self.wrapWidth = wrapWidth
        self.viewportHeight = viewportHeight
        self.contentInset = contentInset
        let initialWords = TeleprompterContentModel.words(
            text: text,
            wordBoundaries: wordBoundaries
        )
        let initialWordIndex = isReadback || wordBoundaries.isEmpty
            ? 0
            : TeleprompterPlaybackPolicy.currentWordIndex(
                in: initialWords,
                elapsedMilliseconds: playbackElapsedMilliseconds() -
                    (TeleprompterPlaybackPolicy.usesServerTimestamps(in: initialWords) ? 0 : estimatedPlaybackStartMilliseconds)
            )
        _currentIndex = State(initialValue: initialWordIndex)
    }

    private static let scrollAnimation: Animation = .smooth(duration: 0.18)

    @State private var contentHeight: CGFloat = 0
    @State private var hoveredWordID: Int?
    @State private var pointerState = TeleprompterPointerState()
    @State private var currentIndex: Int
    @State private var animationTask: Task<Void, Never>?
    @State private var renderCache = TeleprompterRenderCache()
    /// True while the animation task is the one moving `currentIndex`; any restart clears it.
    @State private var isPlaybackStep = false
    /// Words, formatting and blocks, computed once per text and timeline (a highlight tick reuses them).
    private var rendered: TeleprompterRenderedDocument {
        renderCache.document(text: text, wordBoundaries: wordBoundaries, displayBlocks: displayBlocks,
                             hasCompleteDisplay: hasCompleteDisplay)
    }

    private var teleprompterWords: [TeleprompterWord] {
        rendered.words
    }

    private var timedWords: [TeleprompterWord] {
        teleprompterWords.filter { $0.offsetMs != nil }
    }

    private var usesIndexedTiming: Bool {
        wordBoundaries.contains { $0.wordIndex != nil }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(
                .vertical,
                showsIndicators: TeleprompterPlaybackPolicy.showsScrollIndicators(
                    isReadback: isReadback
                )
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    blockViews(proxy)
                }
                .padding(.horizontal, Theme.teleprompterShellInset)
                .frame(width: wrapWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .padding(.horizontal, contentInset)
                .padding(.top, contentInset)
                .padding(.bottom, contentInset + (contentHeight + 2 * contentInset > viewportHeight ? viewportHeight / 2 : 0))
                .frame(
                    maxWidth: .infinity,
                    minHeight: viewportHeight,
                    alignment: TeleprompterScrollPolicy.initialViewportAlignment
                )
            }
            .id(TeleprompterScrollPolicy.contentIdentity(for: text))
            .coordinateSpace(name: "teleprompterViewport")
            .onPreferenceChange(TeleprompterWordFrames.self) { frames in
                TeleprompterLandingProbe.didMeasure?(frames)
            }
            .clipped()
            .onAppear {
                scrollToCurrentWord(with: proxy, animated: false)
                if TeleprompterPlaybackPolicy.animatesTimeline(isReadback: isReadback) {
                    startAnimating()
                }
            }
            .onDisappear {
                stopAnimating()
                pointerState.reset(pop: { NSCursor.pop() })
                hoveredWordID = nil
            }
            .onChange(of: contentHeight) { _, _ in
                scrollToCurrentWord(with: proxy, animated: false)
            }
            .onChange(of: text) { _, _ in
                restart()
                scrollToCurrentWord(with: proxy, animated: false)
            }
            .onChange(of: wordBoundaries) { _, _ in
                // Timings change the clock, not the eagerly measured geometry.
                restart()
            }
            .onChange(of: playbackEpoch) { _, _ in
                restart()
                scrollToCurrentWord(with: proxy, animated: false)
            }
            .onChange(of: currentIndex) { _, _ in
                // Playback glides; explicit timeline jumps land immediately.
                scrollToCurrentWord(with: proxy, animated: isPlaybackStep)
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

    /// One eagerly measured flow per block gives all visible rows the same geometry. A
    /// highlight tick re-renders only the blocks whose inputs changed (the current one, and the one it left).
    private func blockViews(_ proxy: ScrollViewProxy) -> some View {
        let document = rendered
        let indexed = usesIndexedTiming
        let group = TeleprompterFormatting.groupRange(containing: currentIndex, layouts: document.layouts)
        let groupID = document.layouts.indices.contains(currentIndex) ? document.layouts[currentIndex].highlightGroup : nil
        let groupTimed = groupID.map { document.words.indices.contains($0) && canHighlight(document.words[$0], indexed) }
            ?? false
        // Block identity must not share the Int space of word ids, or scrollTo(word) lands on a block.
        return ForEach(document.blocks.indices.map(TeleprompterBlockID.init), id: \.self) { blockID in
            let index = blockID.index, block = document.blocks[index]
            TeleprompterBlockView(
                words: Array(document.words[block]),
                layouts: Array(document.layouts[block]),
                highlightedIndex: blockHighlight(block),
                highlightedGroup: block.overlaps(group) ? groupID : nil,
                highlightedGroupIsTimed: block.overlaps(group) && groupTimed,
                hoveredWordID: hoveredWordID.flatMap { block.contains($0) ? $0 : nil },
                isReadback: isReadback,
                usesIndexedTiming: indexed,
                hasBoundaries: !wordBoundaries.isEmpty,
                wrapWidth: wrapWidth,
                flowWidth: wrapWidth - 2 * Theme.teleprompterShellInset,
                onSeek: onSeek,
                onSeekUnavailable: onSeekUnavailable,
                onHover: updateWordHover
            )
            .equatable()
            .padding(.top, index == 0 ? 0 : document.layouts[block.lowerBound].lineBreak == .paragraph ? 9 : 3)
            .id(blockID)

        }
    }

    /// The word a block styles against. Outside the block it saturates, so a far-away tick changes nothing:
    /// later blocks read as upcoming, earlier ones past the karaoke fade.
    private func canHighlight(_ word: TeleprompterWord, _ indexed: Bool) -> Bool {
        indexed ? word.offsetMs != nil : !wordBoundaries.isEmpty
    }

    private func blockHighlight(_ block: Range<Int>) -> Int {
        if block.contains(currentIndex) { return currentIndex }
        return currentIndex < block.lowerBound ? -1 : min(currentIndex, block.upperBound + 64)
    }

    private func updateWordHover(_ wordID: Int, isInside: Bool) {
        if isInside { hoveredWordID = wordID } else if hoveredWordID == wordID { hoveredWordID = nil }
        pointerState.hover(wordID: wordID, isInside: isInside,
            push: { NSCursor.pointingHand.push() }, pop: { NSCursor.pop() })
    }

    // MARK: - Animation

    private var hasServerTimestamps: Bool {
        TeleprompterPlaybackPolicy.usesServerTimestamps(in: teleprompterWords)
    }

    private var highlightElapsedMilliseconds: Int {
        playbackElapsedMilliseconds() - (hasServerTimestamps ? 0 : estimatedPlaybackStartMilliseconds)
    }

    private func startAnimating() {
        let hasTimeline = usesIndexedTiming ? !timedWords.isEmpty : !wordBoundaries.isEmpty
        guard TeleprompterPlaybackPolicy.animatesTimeline(isReadback: isReadback), hasTimeline else { return }
        isPlaybackStep = false
        currentIndex = TeleprompterPlaybackPolicy.currentWordIndex(
            in: teleprompterWords,
            elapsedMilliseconds: highlightElapsedMilliseconds
        )

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
        let startingWordID = currentIndex

        animationTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterPlaybackPolicy.startupDelay)
            if Task.isCancelled { return }

            for word in words {
                guard let targetOffsetMs = word.offsetMs else { continue }
                guard word.id > startingWordID else { continue }
                await waitForClock(toReach: targetOffsetMs) { playbackElapsedMilliseconds() }
                if Task.isCancelled { break }
                isPlaybackStep = true
                currentIndex = word.id
            }
        }
    }

    /// Client-side estimated animation (fallback for non-edge-tts engines).
    private func startEstimatedAnimation() {
        let words = teleprompterWords
        let startingWordID = currentIndex
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterPlaybackPolicy.startupDelay)
            if Task.isCancelled { return }
            for index in words.indices {
                let word = words[index]
                guard word.id > startingWordID else { continue }
                guard let targetOffsetMilliseconds = TeleprompterPlaybackPolicy.playbackOffsetMilliseconds(
                    forWordAt: index,
                    in: words
                ) else { continue }
                await waitForClock(toReach: targetOffsetMilliseconds) { highlightElapsedMilliseconds }
                if Task.isCancelled { break }
                isPlaybackStep = true
                currentIndex = word.id
            }
        }
    }

    private func waitForClock(toReach targetMilliseconds: Int, elapsed: () -> Int) async {
        while !Task.isCancelled {
            let remainingMilliseconds = targetMilliseconds - elapsed()
            guard remainingMilliseconds > 0 else { return }
            try? await Task.sleep(for: .milliseconds(remainingMilliseconds))
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
        guard rendered.words.indices.contains(currentIndex) else { return }
        // Every block is measured eagerly at the same width. One word anchor is
        // sufficient; block-first and delayed retries used to produce double jumps.
        let anchor: UnitPoint = switch TeleprompterScrollPolicy.position(for: currentIndex) {
        case .top: .top
        case .center: .center
        }
        if animated {
            withAnimation(Self.scrollAnimation) { proxy.scrollTo(currentIndex, anchor: anchor) }
        } else {
            proxy.scrollTo(currentIndex, anchor: anchor)
        }
    }

    /// Restarts the highlight from the clock.
    private func restart() {
        defer { startAnimating() }
        stopAnimating()
        isPlaybackStep = false
        currentIndex = TeleprompterPlaybackPolicy.restartWordIndex(
            in: teleprompterWords, elapsedMilliseconds: highlightElapsedMilliseconds,
            isReadback: isReadback || wordBoundaries.isEmpty
        )
    }
}

struct TeleprompterBlockID: Hashable {
    let index: Int
}

/// One block of the teleprompter: a flow of words with their formatting, karaoke styling and seek buttons.
/// Equatable on its values (closures excluded), so SwiftUI skips every block a highlight tick did not touch.
private struct TeleprompterBlockView: View, Equatable {
    let words: [TeleprompterWord]
    let layouts: [TeleprompterWordLayout]
    let highlightedIndex: Int
    /// The current word's group when it reaches into this block (a long token or punctuation run may span blocks).
    let highlightedGroup: Int?
    let highlightedGroupIsTimed: Bool
    let hoveredWordID: Int?
    let isReadback: Bool
    let usesIndexedTiming: Bool
    let hasBoundaries: Bool
    let wrapWidth: CGFloat
    let flowWidth: CGFloat
    let onSeek: ((Int) -> Void)?
    let onSeekUnavailable: (() -> Void)?
    let onHover: (Int, Bool) -> Void
    @Environment(\.voiceBarNotchAppearance) private var notchAppearance

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.words == rhs.words && lhs.layouts == rhs.layouts && lhs.highlightedIndex == rhs.highlightedIndex &&
            lhs.highlightedGroup == rhs.highlightedGroup && lhs.highlightedGroupIsTimed == rhs.highlightedGroupIsTimed &&
            lhs.hoveredWordID == rhs.hoveredWordID && lhs.isReadback == rhs.isReadback &&
            lhs.usesIndexedTiming == rhs.usesIndexedTiming && lhs.hasBoundaries == rhs.hasBoundaries &&
            lhs.wrapWidth == rhs.wrapWidth && lhs.flowWidth == rhs.flowWidth && (lhs.onSeek == nil) == (rhs.onSeek == nil)
    }

    /// The pill is drawn per word; glued neighbours square off their shared edge so it reads as one.
    private struct WordHighlight {
        let isCurrent: Bool
        let isAvailable: Bool
        let joinsPrevious: Bool
        let joinsNext: Bool
    }

    var body: some View {
        let first = words.first?.id ?? 0
        FlowLayout(spacing: 5, maxWidth: flowWidth) {
            ForEach(Array(words.enumerated()), id: \.element.id) { position, word in
                let layout = layouts[position]
                let head = layout.highlightGroup - first
                let isCurrent = !layout.isListMarker && layout.highlightGroup == highlightedGroup
                let highlight = WordHighlight(
                    isCurrent: isCurrent,
                    isAvailable: !layout.isListMarker && (canHighlight(word) || words.indices.contains(head) && canHighlight(words[head]) ||
                        isCurrent && highlightedGroupIsTimed),
                    joinsPrevious: layout.gluesToPrevious,
                    joinsNext: layouts.indices.contains(position + 1) && layouts[position + 1].gluesToPrevious
                )
                if let marker = layout.decoration {
                    Text(marker)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(notchPalette.primary.color)
                        .accessibilityHidden(true)
                        .layoutValue(key: TeleprompterFlowItemKey.self,
                                     value: TeleprompterFlowItem(lineBreak: layout.lineBreak, isListMarker: true))
                }
                if let separator = layout.separator {
                    Text(separator)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(notchPalette.primary.color.opacity(0.78))
                        .accessibilityHidden(true)
                        .layoutValue(key: TeleprompterFlowItemKey.self,
                                     value: TeleprompterFlowItem(gluesToPrevious: true))
                }
                Group {
                    if let onSeek, isReadback || TeleprompterSeekPolicy.offset(for: word, isReadback: isReadback) != nil {
                        Button {
                            TeleprompterSeekPolicy.seek(word, isReadback: isReadback, seek: onSeek,
                                                        unavailable: { onSeekUnavailable?() })
                        } label: {
                            wordLabel(word, text: layout.displayText, heading: layout.isHeading, highlight: highlight)
                                .underline(hoveredWordID == word.id)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in onHover(word.id, hovering) }
                        .onDisappear { onHover(word.id, false) }
                        .accessibilityHint("Seek to this word")
                        .help("Seek to this word")
                    } else {
                        wordLabel(word, text: layout.displayText, heading: layout.isHeading, highlight: highlight)
                    }
                }
                .background {
                    if TeleprompterLandingProbe.didMeasure != nil {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TeleprompterWordFrames.self,
                                value: [word.id: geometry.frame(in: .named("teleprompterViewport"))])
                        }
                    }
                }
                .id(word.id)
                .layoutValue(key: TeleprompterFlowItemKey.self, value: layout.decoration == nil ? layout.flowItem
                             : TeleprompterFlowItem(gluesToPrevious: layout.gluesToPrevious))
            }
        }
    }

    private func wordLabel(_ word: TeleprompterWord, text: String, heading: Bool, highlight: WordHighlight) -> some View {
        let leading: CGFloat = highlight.joinsPrevious ? 0 : 3, trailing: CGFloat = highlight.joinsNext ? 0 : 3
        return Text(text)
            .font(.system(size: 16, weight: heading ? .semibold : .medium))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: wrapWidth, alignment: .leading)
            .foregroundStyle(wordForeground(word, isCurrent: highlight.isCurrent))
            .background {
                if !isReadback, highlight.isAvailable, highlight.isCurrent || hoveredWordID == word.id {
                    UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading,
                                           bottomTrailingRadius: trailing, topTrailingRadius: trailing)
                        .fill(Color(red: 92/255, green: 124/255, blue: 1).opacity(highlight.isCurrent ? 0.30 : 0.12))
                }
            }
    }

    private func canHighlight(_ word: TeleprompterWord) -> Bool {
        usesIndexedTiming ? word.offsetMs != nil : hasBoundaries
    }

    private func wordForeground(_ word: TeleprompterWord, isCurrent: Bool) -> Color {
        if !isReadback, usesIndexedTiming, word.offsetMs == nil { return notchPalette.primary.color.opacity(0.78) }
        if notchAppearance == .dark, !isReadback, hasBoundaries {
            return isCurrent ? .white : Color(red: 234/255, green: 234/255, blue: 240/255)
        }
        return notchPalette.primary.color.opacity(opacityFor(word.id, highlightedIndex: isCurrent ? word.id : highlightedIndex))
    }

    private func opacityFor(_ index: Int, highlightedIndex: Int) -> Double {
        let minimumOpacity = VoiceBarNotchContrastPalette.minimumTeleprompterOpacity(for: notchAppearance)
        if let readbackOpacity = TeleprompterPlaybackPolicy.wordOpacity(isReadback: isReadback) {
            return readbackOpacity
        }
        if !hasBoundaries { return 0.78 }
        if index == highlightedIndex { return 1.0 }
        if index < highlightedIndex {
            let distance = highlightedIndex - index
            return max(minimumOpacity, 0.90 - Double(distance) * 0.02)
        }
        return max(minimumOpacity, 0.9)
    }

    private var notchPalette: VoiceBarNotchContrastPalette {
        VoiceBarNotchContrastPalette.resolve(for: notchAppearance)
    }
}

/// Mounted word geometry for presentation tests. Never set in production.
@MainActor enum TeleprompterLandingProbe {
    static var didMeasure: (([Int: CGRect]) -> Void)?
}

private struct TeleprompterWordFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
