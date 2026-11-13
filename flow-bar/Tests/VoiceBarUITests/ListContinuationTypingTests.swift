import XCTest
@testable import VoiceBarUI

/// Lane T7: the plan and readback rule for list-aware typed delivery. AX strings below are the values
/// Chrome Beta reported for the T7 fixture editors (docs.local/t7, tests/fixtures/typed-delivery).
final class ListContinuationTypingTests: XCTestCase {
    func testMarkers() {
        XCTAssertEqual(ListContinuationTyping.marker(atStartOf: "1. Buy"), "1. ")
        XCTAssertEqual(ListContinuationTyping.marker(atStartOf: "12) Buy"), "12) ")
        XCTAssertEqual(ListContinuationTyping.marker(atStartOf: "- Buy"), "- ")
        XCTAssertEqual(ListContinuationTyping.marker(atStartOf: "* Buy"), "* ")
        XCTAssertEqual(ListContinuationTyping.marker(atStartOf: "+ Buy"), "+ ")
        for line: Substring in ["1.Buy", "Buy 1. x", " 1. Buy", "-Buy", "1 . x", "", "1.", "v2.4 shipped", "3.5 days"] {
            XCTAssertNil(ListContinuationTyping.marker(atStartOf: line), String(line))
        }
    }

    func testTextWithoutABreakBeforeAListLineKeepsTheOldSingleBatch() {
        for text in ["Just one line of dictated text, nothing else.",
                     "First line of the note.\nSecond line follows here.\nThird line ends it.",
                     "1. a single list line", "Ends with a break\n", ""] {
            XCTAssertNil(ListContinuationTyping.segments(for: text), text)
        }
    }

    func testSegmentsEndOnEveryBreakBeforeAListLineAndConcatenateToTheTranscript() throws {
        let text = "Here's a list of things:\n1. Buy milk\n2. Call him\nNot a list\n- dash"
        let segments = try XCTUnwrap(ListContinuationTyping.segments(for: text))
        XCTAssertEqual(segments, [
            ListContinuationSegment(text: "Here's a list of things:\n", leadingMarker: nil),
            ListContinuationSegment(text: "1. Buy milk\n", leadingMarker: "1. "),
            ListContinuationSegment(text: "2. Call him\nNot a list\n", leadingMarker: "2. "),
            ListContinuationSegment(text: "- dash", leadingMarker: "- "),
        ])
        XCTAssertEqual(segments.map(\.text).joined(), text)
        // The plan of the concatenation is the concatenation of the plans: no marker dropped, same events.
        XCTAssertEqual(segments.flatMap { SynthesizedTyping.keystrokes(for: $0.text) }, SynthesizedTyping.keystrokes(for: text))
    }

    // MARK: readback, from the fixture's real AX values

    func testT3RichListSplitIsReadAsTheEditorsMarker() {
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n", after: "Intro:\n1. Buy milk\n2. \n",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .editorInsertedMarker)
        // Next line typed without our marker: the editor continues with "3. ".
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n1. Buy milk\n2. \n",
                                                   after: "Intro:\n1. Buy milk\n2. Call him\n3. \n",
                                                   typedLine: "Call him\n", nextMarker: "3. "), .editorInsertedMarker)
    }

    func testFirstBreakIntoAnEmptyRichEditorIsPlain() {
        XCTAssertEqual(ListContinuationTyping.read(before: "\n", after: "Intro:\n", typedLine: "Intro:\n", nextMarker: "1. "), .plainBreak)
    }

    func testT3PlainTextContinuationIsReadAsTheEditorsMarker() {
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n", after: "Intro:\n1. Buy milk\n2. ",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .editorInsertedMarker)
    }

    func testPlainEditorsAreReadAsAPlainBreak() {
        // textarea
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n", after: "Intro:\n1. Buy milk\n",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .plainBreak)
        // native contenteditable and stock Tiptap (an empty last line reads as an extra "\n")
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n\n", after: "Intro:\n1. Buy milk\n\n",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .plainBreak)
    }

    func testPaintedBulletCountsAsTheSameBulletButNotAsANumber() {
        XCTAssertEqual(ListContinuationTyping.read(before: "List:\n", after: "List:\n• Passport\n• \n",
                                                   typedLine: "- Passport\n", nextMarker: "- "), .editorInsertedMarker)
        XCTAssertEqual(ListContinuationTyping.read(before: "List:\n", after: "List:\n1. Passport\n• \n",
                                                   typedLine: "1. Passport\n", nextMarker: "2. "), .unknown)
    }

    func testADifferentNumberIsNotTheSameMarker() {
        XCTAssertEqual(ListContinuationTyping.read(before: "", after: "1. a\n2. ", typedLine: "1. a\n", nextMarker: "3. "), .unknown)
    }

    func testExistingTextAfterTheCaretThatLooksLikeTheMarkerIsNotTheEditors() {
        // Dictating into the middle of "A\n2. tail": the "2. " was already there.
        XCTAssertEqual(ListContinuationTyping.read(before: "A\n2. tail", after: "A\n1. x\n2. tail",
                                                   typedLine: "1. x\n", nextMarker: "2. "), .plainBreak)
    }

    func testABreakThatHasNotLandedIsUnknown() {
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n", after: "Intro:\n1. Buy",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .unknown)
        XCTAssertEqual(ListContinuationTyping.read(before: "Intro:\n", after: "Intro:\n1. Buy milk",
                                                   typedLine: "1. Buy milk\n", nextMarker: "2. "), .unknown)
    }
}
