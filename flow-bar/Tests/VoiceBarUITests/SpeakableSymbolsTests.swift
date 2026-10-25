import XCTest
@testable import VoiceBarUI

final class SpeakableSymbolsTests: XCTestCase {
    func testSlashWordsKeepRawGlyphsAndSeparateTiming() {
        let text = "list/paragraph completion/cancellation"
        let rows = ["list", "/paragraph", "completion", "/cancellation"].enumerated().map {
            TeleprompterBoundary(offsetMs: $0.offset * 200, durationMs: 150, text: $0.element, wordIndex: $0.offset)
        }
        let words = TeleprompterContentModel.words(text: text, wordBoundaries: rows)
        XCTAssertEqual(words.map(\.text), rows.map(\.text))
        XCTAssertEqual(words.map(\.offsetMs), [0, 200, 400, 600])
        let layout = TeleprompterFormatting.layout(text: text, words: words)
        XCTAssertEqual(layout.map(\.highlightGroup), [0, 1, 2, 3])
        XCTAssertTrue(layout[1].gluesToPrevious)
    }

    func testPathsURLsAndFractionsStayWhole() {
        for text in ["https://example.com/list/paragraph", "/list/paragraph", "./list/paragraph", "src/input.ts", "1/2", "10/26/2026", "assets/images", "Option+F5"] {
            XCTAssertEqual(TeleprompterContentModel.displayTokens(text), [text])
        }
    }

    func testProtectedAndRepeatedTokensAcceptIndexedBoundaries() {
        for (text, tokens) in [
            ("and/or", ["and/or"]),
            ("`Use list/paragraph here`", ["`Use", "list/paragraph", "here`"]),
            ("`list/paragraph`", ["`list/paragraph`"]),
            ("שלlist/paragraph", ["שלlist/paragraph"]),
            ("list/paragraphשלום", ["list/paragraphשלום"]),
            ("list/paragraph́", ["list/paragraph́"]),
            ("list/paragraph,completion/cancellation", ["list", "/paragraph,completion", "/cancellation"])
        ] {
            XCTAssertEqual(TeleprompterContentModel.displayTokens(text), tokens)
            let rows = tokens.enumerated().map {
                TeleprompterBoundary(offsetMs: 100 + $0.offset * 200, durationMs: 150, text: $0.element, wordIndex: $0.offset)
            }
            let words = TeleprompterContentModel.words(text: text, wordBoundaries: rows)
            XCTAssertEqual(words.map(\.offsetMs), tokens.indices.map { Optional(100 + $0 * 200) })
        }
    }

    func testSourceAdjacencyPreservesDisplaySpacing() {
        for text in ["(list/paragraph)", "list /tmp/file", "list/paragraph,completion/cancellation"] {
            let words = TeleprompterContentModel.words(text: text, wordBoundaries: [])
            let layouts = TeleprompterFormatting.layout(text: text, words: words)
            let rendered = layouts.enumerated().map { i, layout in
                (i == 0 || layout.gluesToPrevious ? "" : " ") + layout.displayText
            }.joined()
            XCTAssertEqual(rendered, text)
        }
    }

    func testSilentBulletDoesNotAcquireInterpolatedTiming() {
        let rows = [TeleprompterBoundary(offsetMs: nil, durationMs: nil, text: "-", wordIndex: 0),
                    TeleprompterBoundary(offsetMs: 200, durationMs: 150, text: "Archive", wordIndex: 1)]
        let result = TeleprompterBoundary.interpolated(rows, text: "- Archive", startMs: 0, endMs: 600)
        XCTAssertNil(result[0].offsetMs)
        XCTAssertNil(result[0].durationMs)
    }
}
