@testable import VoiceBarUI
import XCTest

final class TeleprompterContentModelTests: XCTestCase {
    func testUsesDisplayTextWhilePreservingMatchingBoundaryTimings() {
        let words = TeleprompterContentModel.words(
            text: "This matches speech",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "This"),
                TeleprompterBoundary(offsetMs: 120, durationMs: 110, text: "matches"),
                TeleprompterBoundary(offsetMs: 250, durationMs: 120, text: "speech"),
            ]
        )

        XCTAssertEqual(words.map(\.text), ["This", "matches", "speech"])
        XCTAssertEqual(words.map(\.offsetMs), [0, 120, 250])
    }

    func testPhoneticBoundaryTokensNeverReplaceOriginalDisplayText() {
        let words = TeleprompterContentModel.words(
            text: "Etan runs supabase cmuxlayer golems and BrainLayer",
            wordBoundaries: [
                TeleprompterBoundary(offsetMs: 0, durationMs: 80, text: "Eh"),
                TeleprompterBoundary(offsetMs: 90, durationMs: 110, text: "tahn"),
                TeleprompterBoundary(offsetMs: 220, durationMs: 100, text: "runs"),
                TeleprompterBoundary(offsetMs: 340, durationMs: 90, text: "Soopa"),
                TeleprompterBoundary(offsetMs: 440, durationMs: 100, text: "base"),
                TeleprompterBoundary(offsetMs: 560, durationMs: 120, text: "cmuxlayer"),
                TeleprompterBoundary(offsetMs: 700, durationMs: 80, text: "Go"),
                TeleprompterBoundary(offsetMs: 790, durationMs: 90, text: "lems"),
                TeleprompterBoundary(offsetMs: 900, durationMs: 70, text: "and"),
                TeleprompterBoundary(offsetMs: 990, durationMs: 100, text: "Brain"),
                TeleprompterBoundary(offsetMs: 1100, durationMs: 110, text: "Layer"),
            ]
        )

        XCTAssertEqual(
            words.map(\.text),
            ["Etan", "runs", "supabase", "cmuxlayer", "golems", "and", "BrainLayer"]
        )
        XCTAssertFalse(words.map(\.text).contains("Eh"))
        XCTAssertFalse(words.map(\.text).contains("Soopa"))
    }

    func testInitialWordUsesTopScrollPositionInsteadOfCenteringPastViewportStart() {
        XCTAssertEqual(TeleprompterScrollPolicy.position(for: 0), .top)
        XCTAssertEqual(TeleprompterScrollPolicy.position(for: 1), .center)
    }

    func testFiltersEmptyBoundaryTokensBeforeDrivingHighlighting() {
        let words = TeleprompterContentModel.words(
            text: "Hello world",
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

    func testSplitsLongUnspacedTokensSoTheyCanWrapInsideViewport() {
        let words = TeleprompterContentModel.words(
            text: "SupercalifragilisticexpialidociousShouldNotClip",
            wordBoundaries: []
        )

        XCTAssertGreaterThan(words.count, 1)
        XCTAssertEqual(words.map(\.text).joined(), "SupercalifragilisticexpialidociousShouldNotClip")
        XCTAssertTrue(words.allSatisfy { $0.text.count <= TeleprompterContentModel.maxDisplayTokenLength })
    }
}
