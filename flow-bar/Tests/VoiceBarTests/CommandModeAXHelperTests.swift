@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class CommandModeAXHelperTests: XCTestCase {
    func testApplyReplacementVerifiesAXWriteByReadingBackValue() {
        var storedValue = "hello world"
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: storedValue, selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { newValue in
                storedValue = newValue
                return true
            },
            readBackValue: { storedValue }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .axVerified("Applied to selection"))
        XCTAssertEqual(storedValue, "hello VoiceBar")
    }

    func testApplyReplacementTreatsSuccessfulAXWriteWithStaleReadBackAsSuccess() {
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: "hello world", selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { _ in true },
            readBackValue: { "hello world" }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .axVerified("Applied to selection"))
    }

    func testApplyReplacementDoesNotTouchClipboardWhenAXWriteFails() {
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: "hello world", selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { _ in false },
            readBackValue: { nil }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .failed("AX write failed"))
    }

    func testAssessAXWriteTreatsMismatchAsAppliedUnverified() {
        XCTAssertEqual(
            CommandModeAXHelper.assessAXWrite(
                expectedValue: "new text",
                didWrite: true,
                readBackValue: "stale text"
            ),
            .appliedUnverified
        )
    }

    // MARK: - insertAtCursor: surgical kAXSelectedText insert (wedge guard)

    func testInsertAtCursorUsesSelectedTextWriterAndNeverRewritesWholeValue() {
        var selectedTextWrites: [String] = []
        var wholeValueWrites: [String] = []
        let helper = CommandModeAXHelper(
            writeValue: { value in
                wholeValueWrites.append(value)
                return true
            },
            writeSelectedText: { text in
                selectedTextWrites.append(text)
                return true
            },
            readValueLength: { 12 }
        )

        let inserted = helper.insertAtCursor("VoiceBar")

        XCTAssertTrue(inserted)
        XCTAssertEqual(selectedTextWrites, ["VoiceBar"])
        XCTAssertTrue(wholeValueWrites.isEmpty, "Whole-value rewrite must never run when kAXSelectedText succeeds")
    }

    func testInsertAtCursorFallsBackToValueRewriteWhenSelectedTextFailsOnSmallValue() {
        var storedValue = "hello world"
        var wholeValueWrites: [String] = []
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: storedValue, selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { newValue in
                wholeValueWrites.append(newValue)
                storedValue = newValue
                return true
            },
            readBackValue: { storedValue },
            writeSelectedText: { _ in false },
            readValueLength: { (storedValue as NSString).length }
        )

        let inserted = helper.insertAtCursor("VoiceBar")

        XCTAssertTrue(inserted)
        XCTAssertEqual(wholeValueWrites, ["hello VoiceBar"])
        XCTAssertEqual(storedValue, "hello VoiceBar")
    }

    func testInsertAtCursorReturnsFalseWithoutValueRewriteWhenSelectedTextFailsOnLargeValue() {
        var wholeValueWrites: [String] = []
        let largeLength = CommandModeAXHelper.largeValueThreshold
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(
                    value: String(repeating: "x", count: largeLength),
                    selectedRange: NSRange(location: 0, length: 0)
                )
            },
            writeValue: { value in
                wholeValueWrites.append(value)
                return true
            },
            readBackValue: { nil },
            writeSelectedText: { _ in false },
            readValueLength: { largeLength }
        )

        let inserted = helper.insertAtCursor("nope")

        XCTAssertFalse(inserted)
        XCTAssertTrue(wholeValueWrites.isEmpty, "Large whole-value rewrite must never run (wedge guard)")
    }

    func testInsertAtCursorReturnsFalseWhenSelectedTextFailsAndValueLengthUnknown() {
        var wholeValueWrites: [String] = []
        let helper = CommandModeAXHelper(
            writeValue: { value in
                wholeValueWrites.append(value)
                return true
            },
            writeSelectedText: { _ in false },
            readValueLength: { nil }
        )

        let inserted = helper.insertAtCursor("nope")

        XCTAssertFalse(inserted)
        XCTAssertTrue(wholeValueWrites.isEmpty)
    }
}
