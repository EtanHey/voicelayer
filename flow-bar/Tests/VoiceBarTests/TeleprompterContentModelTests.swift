@testable import VoiceBar
import XCTest

final class TeleprompterContentModelTests: XCTestCase {
    func testUsesBoundaryWordsWhenAvailable() {
        let words = TeleprompterContentModel.words(
            text: "fallback text should not be used",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "This"),
                TeleprompterBoundary(offsetMs: 120, durationMs: 110, text: "matches"),
                TeleprompterBoundary(offsetMs: 250, durationMs: 120, text: "speech"),
            ]
        )

        XCTAssertEqual(words.map(\.text), ["This", "matches", "speech"])
        XCTAssertEqual(words.map(\.offsetMs), [0, 120, 250])
    }

    func testFiltersEmptyBoundaryTokensBeforeDrivingHighlighting() {
        let words = TeleprompterContentModel.words(
            text: "fallback text",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Hello"),
                TeleprompterBoundary(offsetMs: 120, durationMs: 110, text: " "),
                TeleprompterBoundary(offsetMs: 250, durationMs: 120, text: ""),
                TeleprompterBoundary(offsetMs: 380, durationMs: 130, text: "world"),
            ]
        )

        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(words.map(\.offsetMs), [0, 380])
    }

    func testFallsBackToTextSplittingWhenNoBoundaryWordsExist() {
        let words = TeleprompterContentModel.words(
            text: "three visible lines",
            wordBoundaries: []
        )

        XCTAssertEqual(words.map(\.text), ["three", "visible", "lines"])
        XCTAssertEqual(words.map(\.offsetMs), [nil, nil, nil])
    }
}
