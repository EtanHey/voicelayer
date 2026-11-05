import AppKit
import SwiftUI

/// U5, SPEC § Teleprompter A: 24 pt lines of 17 pt text in a 404 pt column. Reading starts on the first line;
/// once the focus line reaches the middle row it holds there and the text slides up one line at a time.
public enum TeleprompterA {
    public static let lineHeight: CGFloat = 24
    public static let fontSize: CGFloat = 17
    public static let columnWidth: CGFloat = 404
    public static let lineRange = 3 ... 8
    public static let topFadeHeight: CGFloat = 16
    public static let footerHeight: CGFloat = 20
    public static let handleSize = CGSize(width: 34, height: 4)

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

    /// Release snaps to whole lines.
    public static func snappedLines(startLines: Int, translation: CGFloat) -> Int {
        clamp(Int(((CGFloat(startLines) * lineHeight + translation) / lineHeight).rounded()))
    }

    public static func clamp(_ lines: Int) -> Int { min(lineRange.upperBound, max(lineRange.lowerBound, lines)) }

    public static func footerState(isPaused: Bool, isPausedForDictation: Bool, rate: String = "1×") -> String {
        isPausedForDictation ? "Paused for your dictation · resumes after paste" : isPaused ? "Paused" : "Reading · \(rate)"
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
        let ends = { (index: Int) in texts[index].last.map { ".!?…".contains($0) } == true }
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
              let offset = (event["wordOffset"] as? NSNumber)?.intValue, (0 ... 1_000_000).contains(offset),
              let rows = event["words"] as? [[String: Any]] else { return false }
        var parsed: [Word] = []
        for row in rows {
            guard let text = row["text"] as? String, let start = (row["startMs"] as? NSNumber)?.doubleValue,
                  let end = (row["endMs"] as? NSNumber)?.doubleValue, start.isFinite, end.isFinite,
                  start >= 0, end >= start else { return false }
            parsed.append(Word(text: text, startMs: Int(start.rounded()), endMs: Int(end.rounded())))
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

    init(document: TeleprompterRenderedDocument, text: String, column: CGFloat) {
        words = document.words
        layouts = document.layouts
        tokens = TeleprompterContentModel.displayTokens(text)
        let pieces = tokens.enumerated().flatMap { index, token in
            Array(repeating: index, count: TeleprompterContentModel.displayPieceCount(token))
        }
        tokenOfWord = pieces.count == words.count ? pieces : nil
        spacing = Self.width(" ", heading: false)
        let widths = layouts.map { layout in
            Self.width((layout.decoration.map { $0 + " " } ?? "") + (layout.separator ?? "") + layout.displayText,
                       heading: layout.isHeading)
        }
        lines = TeleprompterA.lines(widths: widths, breaks: layouts.map { $0.lineBreak != .none },
                                    glues: layouts.map(\.gluesToPrevious), spacing: spacing, column: column)
        var lineOfWord = Array(repeating: 0, count: words.count)
        for (line, range) in lines.enumerated() { for word in range { lineOfWord[word] = line } }
        self.lineOfWord = lineOfWord
    }

    static func width(_ text: String, heading: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TeleprompterA.fontSize, weight: heading ? .semibold : .medium)
        return NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
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
