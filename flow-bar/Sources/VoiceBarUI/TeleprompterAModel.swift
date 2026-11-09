import AppKit
import SwiftUI

/// U5, SPEC § Teleprompter A: 24 pt lines of 17 pt text. Reading starts on the first line; once the focus line
/// reaches the middle row it holds there and the text slides up one line at a time.
public enum TeleprompterA {
    public static let lineHeight: CGFloat = 24
    public static let fontSize: CGFloat = 17
    /// Lane B (2.4, "the teleprompter is wider"): the column is the teleprompter body's whole text width (429 pt at
    /// the 185 pt contract core; it was capped at 404). A wider body widens it with no change here.
    public static var columnWidth: CGFloat { VoiceBarNotchContract.material.teleprompterTextWidth }
    /// Lane B: the greedy wrap leaves this much room, so per-glyph rounding in SwiftUI can never push a line past
    /// the column (that compression is what rendered "Codex" as "Cod…").
    public static let wrapSlack: CGFloat = 2
    public static let lineRange = 3 ... 8
    public static let topFadeHeight: CGFloat = 16
    public static let footerHeight: CGFloat = 20
    public static let handleSize = CGSize(width: 34, height: 4)
    /// The handle's hit band under the footer.
    public static let handleBandHeight: CGFloat = 14

    public enum Tier: Equatable {
        case spoken, read, unread
        public var opacity: Double {
            switch self {
            case .spoken: 1
            case .read: 0.64
            case .unread: 0.36
            }
        }
    }

    public static func tier(group: Int, focusGroup: Int?) -> Tier {
        guard let focusGroup else { return .unread }
        return group == focusGroup ? .spoken : group < focusGroup ? .read : .unread
    }

    /// No scroll until the focus passes the middle row; from then on the focus line holds it.
    public static func scrolledLines(focusLine: Int?, visibleLines: Int) -> Int {
        guard let focusLine else { return 0 }
        return max(0, focusLine - (visibleLines - 1) / 2)
    }

    /// The fade only exists once a line has gone under it.
    public static func showsTopFade(scrolledLines: Int) -> Bool { scrolledLines > 0 }

    /// 240 ms ease-in-out-quart; reduced motion jumps. SwiftUI retargets it when the focus moves again mid-slide.
    public static func slide(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    }

    public static let pull = Animation.spring(response: 0.38, dampingFraction: 0.86)

    public static func bodyHeight(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight + footerHeight }

    /// Handle drag: follows the pointer inside 3–8 lines and rubber-bands past either end (at most one line).
    public static func draggedHeight(startLines: Int, translation: CGFloat) -> CGFloat {
        let raw = CGFloat(startLines) * lineHeight + translation
        let low = CGFloat(lineRange.lowerBound) * lineHeight, high = CGFloat(lineRange.upperBound) * lineHeight
        func band(_ overshoot: CGFloat) -> CGFloat { lineHeight * (1 - 1 / (overshoot / lineHeight * 0.55 + 1)) }
        if raw < low { return low - band(low - raw) }
        if raw > high { return high + band(raw - high) }
        return raw
    }

    /// Past either end the panel stays at 3 or 8 lines and the handle itself stretches with the band.
    public static func handleOvershoot(startLines: Int, translation: CGFloat) -> CGFloat {
        let height = draggedHeight(startLines: startLines, translation: translation)
        return height - min(max(height, CGFloat(lineRange.lowerBound) * lineHeight), CGFloat(lineRange.upperBound) * lineHeight)
    }

    /// Release snaps to whole lines.
    public static func snappedLines(startLines: Int, translation: CGFloat) -> Int {
        clamp(Int(((CGFloat(startLines) * lineHeight + translation) / lineHeight).rounded()))
    }

    public static func clamp(_ lines: Int) -> Int { min(lineRange.upperBound, max(lineRange.lowerBound, lines)) }

    /// Lane B (Etan, 2026-11-08 "less empty space"): the rows a read needs. The handle's choice (3–8) is an upper
    /// bound; a read that wraps to fewer lines needs only those (at least one). The shell sizes from this.
    public static func fittedLines(preferred: Int, textLines: Int) -> Int {
        max(1, min(clamp(preferred), textLines))
    }

    /// Lane B: the speed is its own control now (the footer chip), so the state reads "Reading" alone.
    public static func footerState(isPaused: Bool, isPausedForDictation: Bool) -> String {
        isPausedForDictation ? "Paused for your dictation · resumes after paste" : isPaused ? "Paused" : "Reading"
    }

    public static func queuedChip(_ count: Int) -> String? { count > 0 ? "+\(count) queued" : nil }

    /// Greedy wrap on measured widths. A forced break starts a line; a glued word never takes a space.
    public static func lines(widths: [CGFloat], breaks: [Bool], glues: [Bool], spacing: CGFloat,
                             column: CGFloat) -> [Range<Int>] {
        var result: [Range<Int>] = [], start = 0, used: CGFloat = 0
        for index in widths.indices {
            let gap: CGFloat = index == start || glues[index] ? 0 : spacing
            if index > start, breaks[index] || used + gap + widths[index] > column {
                result.append(start ..< index); start = index; used = widths[index]
            } else {
                used += gap + widths[index]
            }
        }
        if start < widths.count { result.append(start ..< widths.count) }
        return result
    }

    /// The sentence around the focus word, for VoiceOver's value.
    public static func sentence(_ texts: [String], around focus: Int?) -> String {
        guard !texts.isEmpty else { return "" }
        let at = min(max(focus ?? 0, 0), texts.count - 1)
        // A terminator still ends the sentence behind closing quotes or brackets: `"Hello."`, `(done.)`.
        let ends = { (index: Int) in
            texts[index].reversed().drop { "\"'”’)]".contains($0) }.first.map { ".!?…".contains($0) } == true
        }
        var lower = at
        while lower > 0, !ends(lower - 1) { lower -= 1 }
        var upper = at
        while upper < texts.count - 1, !ends(upper) { upper += 1 }
        return texts[lower ... upper].joined(separator: " ")
    }
}

/// The daemon's `speech_words` table for one utterance: global display-token indices, absolute utterance ms.
public struct SpeechWordTable: Equatable {
    public struct Word: Equatable {
        public let text: String
        public let startMs: Int
        public let endMs: Int
    }

    public let utteranceID: String
    public private(set) var words: [Word?] = []

    public init(utteranceID: String) { self.utteranceID = utteranceID }

    /// One upsert at `wordOffset`. Another utterance's or a malformed payload changes nothing.
    @discardableResult
    public mutating func apply(_ event: [String: Any]) -> Bool {
        guard event["utteranceId"] as? String == utteranceID,
              let offset = (event["wordOffset"] as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }),
              (0 ... 1_000_000).contains(offset),
              let rows = event["words"] as? [[String: Any]] else { return false }
        // Every row converts before anything changes: a time outside Int (1e20) or NaN rejects the payload
        // instead of trapping, and a skipped row would shift every later word's index.
        func milliseconds(_ value: Any?) -> Int? {
            (value as? NSNumber).flatMap { $0.doubleValue.isFinite ? Int(exactly: $0.doubleValue.rounded()) : nil }
        }
        var parsed: [Word] = []
        for row in rows {
            guard let text = row["text"] as? String, let start = milliseconds(row["startMs"]),
                  let end = milliseconds(row["endMs"]), start >= 0, end >= start else { return false }
            parsed.append(Word(text: text, startMs: start, endMs: end))
        }
        if words.count < offset + parsed.count { words += Array(repeating: nil, count: offset + parsed.count - words.count) }
        for (index, word) in parsed.enumerated() { words[offset + index] = word }
        return true
    }

    /// The last word whose start the utterance clock has reached; nil before the first.
    public func wordIndex(atMilliseconds milliseconds: Int) -> Int? {
        var found: Int?
        for (index, word) in words.enumerated() {
            guard let word else { continue }
            if word.startMs > milliseconds { break }
            found = index
        }
        return found
    }

    /// A click seeks only the same text at the same index; anything else is not ours to name.
    public func seekIndex(token: Int, text: String) -> Int? {
        words.indices.contains(token) && words[token]?.text == text ? token : nil
    }
}

/// Words, formatting and wrapped lines for one text at one column width; a clock tick reuses it.
struct TeleprompterAModel {
    let words: [TeleprompterWord]
    let layouts: [TeleprompterWordLayout]
    /// Display word (a long token's piece) → display-token index, when the pieces partition the tokens.
    let tokenOfWord: [Int]?
    let tokens: [String]
    let lines: [Range<Int>]
    let lineOfWord: [Int]
    let spacing: CGFloat
    /// Lane B: measured width of each word as rendered (decoration, separator and text are separate Text views).
    let widths: [CGFloat]
    /// Lane B: a single word wider than the column scales down to fit on its own line; it is never cut.
    let shrinks: [Bool]
    /// Lane B: no space before this word. Glued punctuation, and every later piece of a long token (the
    /// document splits tokens over 24 characters; drawn with a space they read "antidisestablishmentaria nism").
    let glued: [Bool]
    let column: CGFloat

    init(document: TeleprompterRenderedDocument, text: String, column: CGFloat) {
        words = document.words
        layouts = document.layouts
        tokens = TeleprompterContentModel.displayTokens(text)
        let pieces = tokens.enumerated().flatMap { index, token in
            Array(repeating: index, count: TeleprompterContentModel.displayPieceCount(token))
        }
        tokenOfWord = pieces.count == words.count ? pieces : nil
        spacing = Self.width(" ", heading: false)
        let widths = layouts.map(Self.renderedWidth)
        self.widths = widths
        self.column = column
        let usable = max(1, column - TeleprompterA.wrapSlack)
        shrinks = widths.map { $0 > usable }
        var glued: [Bool] = []
        for index in layouts.indices {
            var sameToken = false
            if index > 0, let owner = tokenOfWord { sameToken = owner[index] == owner[index - 1] }
            glued.append(layouts[index].gluesToPrevious || sameToken)
        }
        self.glued = glued
        lines = TeleprompterA.lines(widths: widths.map { min($0, usable) }, breaks: layouts.map { $0.lineBreak != .none },
                                    glues: glued, spacing: spacing, column: usable)
        var lineOfWord = Array(repeating: 0, count: words.count)
        for (line, range) in lines.enumerated() { for word in range { lineOfWord[word] = line } }
        self.lineOfWord = lineOfWord
    }

    static func width(_ text: String, heading: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TeleprompterA.fontSize, weight: heading ? .semibold : .medium)
        return NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
    }

    /// The word as `lineView` draws it: up to three Text views side by side, each rounded up on its own.
    static func renderedWidth(_ layout: TeleprompterWordLayout) -> CGFloat {
        let heading = layout.isHeading
        return (layout.decoration.map { width($0 + " ", heading: heading) } ?? 0)
            + (layout.separator.map { width($0, heading: heading) } ?? 0)
            + width(layout.displayText, heading: heading)
    }

    /// The word the clock names: the daemon's table when it covers this text, else the subtitle timeline.
    func focusWord(table: SpeechWordTable?, clock: Int) -> Int? {
        if let table, let tokenOfWord, !table.words.isEmpty {
            guard let token = table.wordIndex(atMilliseconds: clock) else { return nil }
            return tokenOfWord.firstIndex(of: token)
        }
        guard TeleprompterPlaybackPolicy.usesServerTimestamps(in: words) else { return nil }
        let id = TeleprompterPlaybackPolicy.currentWordIndex(in: words, elapsedMilliseconds: clock)
        return words.indices.contains(id) ? id : nil
    }

    enum SeekTarget: Equatable { case word(utteranceID: String, index: Int), offset(Int) }

    func seekTarget(for word: Int, table: SpeechWordTable?) -> SeekTarget? {
        if let table, let token = tokenOfWord?[word], let index = table.seekIndex(token: token, text: tokens[token]) {
            return .word(utteranceID: table.utteranceID, index: index)
        }
        return TeleprompterSeekPolicy.offset(for: words[word], isReadback: false).map(SeekTarget.offset)
    }
}

final class TeleprompterAModelCache {
    private var key: (text: String, boundaries: [TeleprompterBoundary], blocks: [TeleprompterDisplayBlock],
                      complete: Bool, column: CGFloat)?
    private var cached: TeleprompterAModel?
    private let documents = TeleprompterRenderCache()

    func model(text: String, boundaries: [TeleprompterBoundary], blocks: [TeleprompterDisplayBlock],
               complete: Bool, column: CGFloat) -> TeleprompterAModel {
        if let key, let cached, key.text == text, key.boundaries == boundaries, key.blocks == blocks,
           key.complete == complete, key.column == column { return cached }
        let model = TeleprompterAModel(document: documents.document(
            text: text, wordBoundaries: boundaries, displayBlocks: blocks, hasCompleteDisplay: complete),
            text: text, column: column)
        key = (text, boundaries, blocks, complete, column)
        cached = model
        return model
    }
}
