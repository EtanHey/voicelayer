import SwiftUI
import XCTest
@testable import VoiceBarUI

/// TELE1: display-only formatting. Bullets and numbers on their own lines, paragraph breaks kept,
/// one space after a sentence end, punctuation flush with its word, timing identity untouched.
final class TeleprompterFormattingTests: XCTestCase {
    private func layout(_ text: String) -> [TeleprompterWordLayout] {
        TeleprompterFormatting.layout(text: text, words: TeleprompterContentModel.words(text: text, wordBoundaries: []))
    }

    func testBulletsStartTheirOwnLineWithAHangingIndent() {
        let result = layout("Shipped: • Notch message fixed\n• Word timing\n- Dash item\nA - B")
        XCTAssertEqual(result.map(\.displayText),
                       ["Shipped:", "•", "Notch", "message", "fixed", "•", "Word", "timing", "-", "Dash", "item",
                        "A", "-", "B"])
        XCTAssertEqual(result.map(\.lineBreak),
                       [.none, .line, .none, .none, .none, .line, .none, .none, .line, .none, .none,
                        .line, .none, .none])
        XCTAssertEqual(result.map(\.isListMarker),
                       [false, true, false, false, false, true, false, false, true, false, false,
                        false, false, false], "a dash mid-line is a dash, not a bullet")
    }

    func testNumberedItemsAndParagraphBreaks() {
        let result = layout("Steps:\n1. Open it\n2) Close it\n\nDone. Item 3. stays inline")
        XCTAssertEqual(result.map(\.lineBreak),
                       [.none, .line, .none, .none, .line, .none, .none, .paragraph, .none, .none, .none, .none])
        XCTAssertEqual(result.map(\.isListMarker),
                       [false, true, false, false, true, false, false, false, false, false, false, false])
    }

    func testMissingSpaceAfterSentenceEndIsDisplayedWithOne() {
        XCTAssertEqual(layout("unmuted.What anymore.The loud!Pause why?No").map(\.displayText),
                       ["unmuted. What", "anymore. The", "loud! Pause", "why? No"])
        XCTAssertEqual(layout("v2.2.48 U.S.A e.g. Node.js 3.5x").map(\.displayText),
                       ["v2.2.48", "U.S.A", "e.g.", "Node.js", "3.5x"], "versions and abbreviations stay")
    }

    func testPunctuationGluesToItsWordAndSharesItsHighlight() {
        let result = layout("word , next ; end .")
        XCTAssertEqual(result.map(\.gluesToPrevious), [false, true, false, true, false, true])
        XCTAssertEqual(result.map(\.highlightGroup), [0, 0, 2, 2, 4, 4],
                       "the pill covers word and punctuation as one")
    }

    func testNormalizationNeverChangesWordIdentityOrTiming() {
        let text = "Intro:\n• unmuted.What , next\n\n1. done"
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let boundaries = tokens.enumerated().map { index, token in
            TeleprompterBoundary(offsetMs: index * 100, durationMs: 90, text: token, wordIndex: index)
        }
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: boundaries)
        let flat = TeleprompterContentModel.words(text: tokens.joined(separator: " "), wordBoundaries: boundaries)
        XCTAssertEqual(words, flat, "line breaks and bullets are display-only")
        XCTAssertEqual(words.map(\.text), tokens, "spoken tokens are never rewritten")
        XCTAssertEqual(words.map(\.offsetMs), tokens.indices.map { $0 * 100 })
        let result = TeleprompterFormatting.layout(text: text, words: words)
        XCTAssertEqual(result.count, words.count, "one layout per timed word")
        XCTAssertEqual(result[2].displayText, "unmuted. What")
    }

    func testFlowLayoutHangsWrappedListLinesUnderTheItemText() {
        let sizes = Array(repeating: CGSize(width: 40, height: 10), count: 5)
        var items = Array(repeating: TeleprompterFlowItem(), count: 5)
        items[0] = TeleprompterFlowItem(lineBreak: .none, isListMarker: true)
        items[4] = TeleprompterFlowItem(gluesToPrevious: true)
        let result = FlowLayout.arrange(sizes: sizes, items: items, maxWidth: 140, spacing: 5)
        XCTAssertEqual(result.positions.map(\.x), [0, 45, 90, 45, 85],
                       "a wrapped line starts under the item text; glued punctuation sits flush")
        XCTAssertEqual(result.positions.map(\.y), [0, 0, 0, 13, 13])
        let plain = FlowLayout.arrange(sizes: sizes, items: Array(repeating: TeleprompterFlowItem(), count: 5),
                                       maxWidth: 140, spacing: 5)
        XCTAssertEqual(plain.positions.map(\.x), [0, 45, 90, 0, 45], "unformatted text wraps exactly as before")
    }

    func testBlocksBreakOnlyWhereTheTextAlreadyBreaksOrAfterALongSentence() {
        let text = "Intro line.\n• item one , two\n\nA long one. Sentence two. Three."
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: [])
        let layouts = TeleprompterFormatting.layout(text: text, words: words)
        XCTAssertEqual(TeleprompterFormatting.blocks(layouts: layouts, words: words, maximumWords: 100),
                       [0 ..< 2, 2 ..< 7, 7 ..< 13])
        XCTAssertEqual(TeleprompterFormatting.blocks(layouts: layouts, words: words, maximumWords: 3),
                       [0 ..< 2, 2 ..< 7, 7 ..< 10, 10 ..< 13],
                       "an over-long paragraph splits only after a sentence end; a list item never splits mid-line")
    }

    func testTheRenderedDocumentIsCachedPerTextAndTimeline() {
        let cache = TeleprompterRenderCache()
        let boundaries = [TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "a", wordIndex: 0)]
        let first = cache.document(text: "a b", wordBoundaries: boundaries)
        XCTAssertEqual(cache.document(text: "a b", wordBoundaries: boundaries).words, first.words)
        XCTAssertEqual(cache.computations, 1, "a highlight tick never reformats the document")
        _ = cache.document(text: "a b c", wordBoundaries: boundaries)
        XCTAssertEqual(cache.computations, 2)
    }
}
