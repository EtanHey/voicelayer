import XCTest
@testable import VoiceBarUI

final class SpeakableSymbolsTests: XCTestCase {
    func testURLFragmentsAndMultiBacktickCodeStayLexical() {
        for text in ["https://x.com/a#b", "https://x.com/a?q=", "https://example.com#client/server", "https://example.com?next=client/server", "``a/b``", "``a` client/server `b``", "```\nclient/server\n```", "```ts\nconst x = `client/server`;\n```", "````\n```\nclient/server\n```\n````"] {
            XCTAssertEqual(TeleprompterContentModel.displayTokens(text), text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        }
    }

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
            ("and/or", ["and", "/or"]),
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

    func testGeneralCompoundsAndRouteProtection() {
        for text in ["client/server", "List/Paragraph", "read/write", "lists/paragraph"] {
            XCTAssertEqual(TeleprompterContentModel.displayTokens(text), text.components(separatedBy: "/").enumerated().map { $0.offset == 0 ? $0.element : "/" + $0.element })
        }
        for text in ["km/h", "TCP/IP", "I/O", "he/she", "[x](list/paragraph)", "list/paragraph?q=1", "list/paragraph#x", "list/paragraph%20x", "list/paragraph@v1", "list/paragraph:foo"] {
            XCTAssertEqual(TeleprompterContentModel.displayTokens(text), [text])
        }
    }

    func testChunkBoundaryResetsStrayBacktickContext() {
        let chunks = ["Press the ` key now.", "Use list/paragraph with `code` later."]
        let text = chunks.joined(separator: "\u{2029}")
        let tokens = chunks.flatMap { TeleprompterContentModel.displayTokens($0) }
        XCTAssertEqual(TeleprompterContentModel.displayTokens(text), tokens)
        let doc = TeleprompterLongReadDocument(longRead: ["id": "read", "text": text, "chunk_count": 2, "chunk_word_starts": [0, 5]])
        XCTAssertEqual(doc?.wordStart(chunkIndex: 1, chunkCount: 2, text: chunks[1]), 5)
    }

    func testOnlyLineStartMarkersLoseInterpolation() {
        for separator in ["\n  ", " "] {
            let text = "before" + separator + "+ after"
            let rows = [TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "before", wordIndex: 0),
                        TeleprompterBoundary(offsetMs: 600, durationMs: 100, text: "after", wordIndex: 2)]
            let result = TeleprompterBoundary.interpolated(rows, text: text, startMs: 0, endMs: 1000)
            XCTAssertEqual(result[1].offsetMs, separator.contains("\n") ? nil : 100)
            let words = TeleprompterContentModel.words(text: text, wordBoundaries: result)
            XCTAssertEqual(TeleprompterFormatting.layout(text: text, words: words)[1].isListMarker, separator.contains("\n"))
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
