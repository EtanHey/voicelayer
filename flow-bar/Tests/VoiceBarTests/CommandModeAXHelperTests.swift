@testable import VoiceBar
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
            readBackValue: { storedValue },
            writePasteboard: { _ in },
            postPasteShortcut: { false }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .axVerified("Applied to selection"))
        XCTAssertEqual(storedValue, "hello VoiceBar")
    }

    func testApplyReplacementFallsBackToClipboardWhenAXVerificationFails() {
        var pastedText: String?
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: "hello world", selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { _ in true },
            readBackValue: { "hello world" },
            writePasteboard: { pastedText = $0 },
            postPasteShortcut: { true }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .clipboardFallback("Pasted fallback"))
        XCTAssertEqual(pastedText, "VoiceBar")
    }
}
