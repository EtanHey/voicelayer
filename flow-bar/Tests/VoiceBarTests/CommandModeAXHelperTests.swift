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
            readBackValue: { storedValue },
            writePasteboard: { _ in },
            postPasteShortcut: { false }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .axVerified("Applied to selection"))
        XCTAssertEqual(storedValue, "hello VoiceBar")
    }

    func testApplyReplacementTreatsSuccessfulAXWriteWithStaleReadBackAsSuccess() {
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

        XCTAssertEqual(result, .axVerified("Applied to selection"))
        XCTAssertNil(pastedText)
    }

    func testApplyReplacementFallsBackToClipboardWhenAXWriteFails() {
        var pastedText: String?
        let helper = CommandModeAXHelper(
            readSelection: {
                CommandModeSelectionSnapshot(value: "hello world", selectedRange: NSRange(location: 6, length: 5))
            },
            writeValue: { _ in false },
            readBackValue: { nil },
            writePasteboard: { pastedText = $0 },
            postPasteShortcut: { true }
        )

        let result = helper.applyReplacement("VoiceBar")

        XCTAssertEqual(result, .clipboardFallback("Pasted fallback"))
        XCTAssertEqual(pastedText, "VoiceBar")
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

    func testLargeCmuxTerminalInsertionUsesSelectedTextStreamingPlan() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: String(repeating: "large transcript chunk ", count: 300),
            focusedValueLength: 120_000,
            targetBundleIdentifier: "com.cmuxterm.app"
        )

        XCTAssertEqual(
            strategy,
            .selectedTextStreaming(maxChunkUTF16Length: 240, interChunkDelay: 0.012)
        )
    }

    func testSelectedTextChunksPreserveTranscriptWithBoundedChunks() {
        let transcript = String(repeating: "alpha beta gamma delta epsilon\n", count: 80)

        let chunks = CommandModeAXHelper.selectedTextChunks(
            for: transcript,
            maxUTF16Length: 64
        )

        XCTAssertEqual(chunks.joined(), transcript)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { ($0 as NSString).length <= 64 })
    }

    func testSelectedTextChunksSplitOversizedGraphemeWithinUTF16Bound() {
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 300)

        let chunks = CommandModeAXHelper.selectedTextChunks(
            for: oversizedGrapheme,
            maxUTF16Length: 64
        )

        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertEqual(chunks.joined(), oversizedGrapheme)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { ($0 as NSString).length <= 64 })
    }

    func testSelectedTextStreamingSuppressesWholeTranscriptFallbackAfterPartialWrite() {
        var attemptedChunks: [String] = []

        let disposition = CommandModeAXHelper.selectedTextStreamingDisposition(
            for: "abcdefgh",
            maxUTF16Length: 4,
            interChunkDelay: 0,
            writeChunk: { chunk in
                attemptedChunks.append(chunk)
                return attemptedChunks.count == 1
            },
            sleep: { _ in }
        )

        XCTAssertEqual(attemptedChunks, ["abcd", "efgh"])
        XCTAssertEqual(
            disposition,
            .partiallyApplied(writtenChunkCount: 1, totalChunkCount: 2)
        )
        XCTAssertTrue(disposition.suppressesWholeTranscriptFallback)
    }
}
