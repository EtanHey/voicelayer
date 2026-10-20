// TeleprompterFormatting.swift — TELE1: line breaks, list items, sentence spacing and punctuation glue.
//
// Formatting is display-only. It never rewrites a spoken token or the word identity timing uses:
// every layout belongs to exactly one TeleprompterWord, by id.

import SwiftUI

public enum TeleprompterLineBreak: Equatable, Sendable {
    case none, line, paragraph
}

/// How one word sits in the flow. Defaults lay out exactly as unformatted text.
public struct TeleprompterFlowItem: Equatable, Sendable {
    public var lineBreak: TeleprompterLineBreak
    /// A bullet or number: the item's wrapped lines hang under the text after it.
    public var isListMarker: Bool
    /// Closing punctuation sits flush against its word and never wraps alone.
    public var gluesToPrevious: Bool

    public init(lineBreak: TeleprompterLineBreak = .none, isListMarker: Bool = false, gluesToPrevious: Bool = false) {
        self.lineBreak = lineBreak
        self.isListMarker = isListMarker
        self.gluesToPrevious = gluesToPrevious
    }
}

struct TeleprompterFlowItemKey: LayoutValueKey {
    static let defaultValue = TeleprompterFlowItem()
}

public struct TeleprompterWordLayout: Equatable {
    public var displayText: String
    public var lineBreak: TeleprompterLineBreak = .none
    public var isListMarker = false
    public var gluesToPrevious = false
    /// Words that light up as one: a token's pieces, and punctuation glued to its word.
    public var highlightGroup: Int

    var flowItem: TeleprompterFlowItem {
        TeleprompterFlowItem(lineBreak: lineBreak, isListMarker: isListMarker, gluesToPrevious: gluesToPrevious)
    }
}

public enum TeleprompterFormatting {
    private static let bullets: Set<String> = ["•", "◦", "▪", "‣"]
    private static let lineStartBullets: Set<String> = ["-", "*", "+", "–"]
    private static let closingPunctuation = Set(",.;:!?)]}…”’»%")

    /// One layout per word, from the whitespace the text had around each token. Words that do not
    /// come from `text` (a boundary-only payload) keep today's plain flow.
    public static func layout(text: String, words: [TeleprompterWord]) -> [TeleprompterWordLayout] {
        let plain = words.map { TeleprompterWordLayout(displayText: $0.text, highlightGroup: $0.id) }
        var tokens: [(text: String, newlines: Int)] = []
        var newlines = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if text[index].isNewline { newlines += 1 }
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            tokens.append((String(text[start ..< index]), newlines))
            newlines = 0
        }
        let tokenOfWord = tokens.indices.flatMap { token in
            Array(repeating: token, count: TeleprompterContentModel.displayPieceCount(tokens[token].text))
        }
        guard tokenOfWord.count == words.count, words.enumerated().allSatisfy({ $0.element.id == $0.offset }) else {
            return plain
        }
        var result = plain
        for (position, word) in words.enumerated() {
            result[position].displayText = spacedSentenceEnds(word.text)
            let tokenIndex = tokenOfWord[position]
            guard position == 0 || tokenOfWord[position - 1] != tokenIndex else {
                result[position].highlightGroup = result[position - 1].highlightGroup
                continue
            }
            let (token, breaks) = tokens[tokenIndex]
            guard tokenIndex > 0 else {
                result[position].isListMarker = isLineStartMarker(token)
                continue
            }
            var lineBreak: TeleprompterLineBreak = breaks >= 2 ? .paragraph : breaks == 1 ? .line : .none
            let isMarker = bullets.contains(token) || (lineBreak != .none && isLineStartMarker(token))
            if isMarker, lineBreak == .none { lineBreak = .line }
            let glues = lineBreak == .none && token.allSatisfy(closingPunctuation.contains)
            result[position].lineBreak = lineBreak
            result[position].isListMarker = isMarker
            result[position].gluesToPrevious = glues
            if glues { result[position].highlightGroup = result[position - 1].highlightGroup }
        }
        return result
    }

    private static func isLineStartMarker(_ token: String) -> Bool {
        if bullets.contains(token) || lineStartBullets.contains(token) { return true }
        guard let last = token.last, last == "." || last == ")" else { return false }
        let digits = token.dropLast()
        return (1 ... 3).contains(digits.count) && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    /// "unmuted.What" displays as "unmuted. What". Only a lowercase word ending a sentence against a
    /// capital qualifies, so versions, abbreviations and file names stay as written.
    static func spacedSentenceEnds(_ token: String) -> String {
        let characters = Array(token)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            output.append(character)
            guard ".?!".contains(character), index > 0,
                  characters[index - 1].isLowercase || ")]\"'”’".contains(characters[index - 1]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, ".?!".contains(characters[end]) {
                output.append(characters[end])
                end += 1
            }
            if end < characters.count, characters[end].isUppercase { output.append(" ") }
            index = end
        }
        return output
    }
}

// MARK: - Rendering blocks and cache

extension TeleprompterFormatting {
    /// Word ranges rendered as independent flows in a lazy stack, so a long read only lays out what is on
    /// screen. A block starts where the text already starts a line; a paragraph longer than
    /// `maximumWords` also splits after a sentence end, never before glued punctuation or inside a token.
    static func blocks(layouts: [TeleprompterWordLayout], words: [TeleprompterWord],
                       maximumWords: Int = 160) -> [Range<Int>] {
        guard layouts.count == words.count, !words.isEmpty else { return words.isEmpty ? [] : [0 ..< words.count] }
        var blocks: [Range<Int>] = []
        var start = 0
        for index in 1 ..< words.count {
            let layout = layouts[index]
            let startsGroup = layout.highlightGroup == words[index].id
            let afterSentence = index - start >= maximumWords && startsGroup &&
                words[index - 1].text.last.map { ".?!".contains($0) } == true
            if layout.lineBreak != .none || afterSentence {
                blocks.append(start ..< index)
                start = index
            }
        }
        blocks.append(start ..< words.count)
        return blocks
    }
}

/// Everything the teleprompter derives from its text and timeline, computed once per document.
public struct TeleprompterRenderedDocument {
    public let words: [TeleprompterWord]
    public let layouts: [TeleprompterWordLayout]
    public let blocks: [Range<Int>]
    /// Block index of every word.
    let blockOfWord: [Int]
}

/// A highlight tick re-renders the view, never the document: formatting reruns only for new text or timings.
public final class TeleprompterRenderCache {
    private var key: (text: String, wordBoundaries: [TeleprompterBoundary])?
    private var cached: TeleprompterRenderedDocument?
    private(set) var computations = 0

    public init() {}

    public func document(text: String, wordBoundaries: [TeleprompterBoundary]) -> TeleprompterRenderedDocument {
        if let key, let cached, key.text == text, key.wordBoundaries == wordBoundaries { return cached }
        computations += 1
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: wordBoundaries)
        let layouts = TeleprompterFormatting.layout(text: text, words: words)
        let blocks = TeleprompterFormatting.blocks(layouts: layouts, words: words)
        var blockOfWord = Array(repeating: 0, count: words.count)
        for (index, block) in blocks.enumerated() { for word in block { blockOfWord[word] = index } }
        let document = TeleprompterRenderedDocument(words: words, layouts: layouts, blocks: blocks,
                                                    blockOfWord: blockOfWord)
        key = (text, wordBoundaries)
        cached = document
        return document
    }
}
