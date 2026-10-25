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

    func testSilentBulletDoesNotAcquireInterpolatedTiming() {
        let rows = [TeleprompterBoundary(offsetMs: nil, durationMs: nil, text: "-", wordIndex: 0),
                    TeleprompterBoundary(offsetMs: 200, durationMs: 150, text: "Archive", wordIndex: 1)]
        let result = TeleprompterBoundary.interpolated(rows, text: "- Archive", startMs: 0, endMs: 600)
        XCTAssertNil(result[0].offsetMs)
        XCTAssertNil(result[0].durationMs)
    }
}
