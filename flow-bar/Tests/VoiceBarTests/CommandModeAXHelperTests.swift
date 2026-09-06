import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class CommandModeAXHelperTests: XCTestCase {
    private final class FakeRunningApplication: NSRunningApplication, @unchecked Sendable {
        private let bundleID: String
        private let pid: pid_t

        init(bundleIdentifier: String = "com.cmuxterm.app", processIdentifier: pid_t = 42424) {
            bundleID = bundleIdentifier
            pid = processIdentifier
            super.init()
        }

        override var bundleIdentifier: String? {
            bundleID
        }

        override var processIdentifier: pid_t {
            pid
        }
    }

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

    func testVeryLongCmuxTerminalInsertionUsesSingleValueRewritePlan() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: String(repeating: "very long transcript chunk ", count: 500),
            focusedValueLength: 120_000,
            targetBundleIdentifier: "com.cmuxterm.app"
        )

        XCTAssertEqual(strategy, .valueRewrite)
    }

    func testVeryLongNonterminalInsertionKeepsSelectedTextStreamingPlan() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: String(repeating: "very long transcript chunk ", count: 500),
            focusedValueLength: 120_000,
            targetBundleIdentifier: "com.example.document-editor"
        )

        XCTAssertEqual(
            strategy,
            .selectedTextStreaming(maxChunkUTF16Length: 240, interChunkDelay: 0.012)
        )
    }

    func testOrdinaryF5FinishIntoCmuxKeepsReliableValueRewritePlan() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: "ordinary F5 transcript completed into the focused cmux pane",
            focusedValueLength: 12000,
            targetBundleIdentifier: "com.cmuxterm.app"
        )

        XCTAssertEqual(strategy, .valueRewrite)
    }

    /// Was `testF5FinishTranscriptionFiresReliableAXInsertionIntoCmuxTarget`, which
    /// asserted the AX value-rewrite reached cmux. PR #24 (`0903372`) routed every
    /// terminal target through the clipboard instead, because AX insertion is
    /// unbracketed and each newline arrives at the shell as a Return. The strategy
    /// contract for cmux is unchanged and still covered by
    /// `testOrdinaryF5FinishIntoCmuxKeepsReliableValueRewritePlan`; what changed is
    /// which path a finished F5 transcript takes to get there.
    func testF5FinishTranscriptionReachesCmuxThroughTheClipboardNotAX() {
        let state = VoiceState()
        let cmux = FakeRunningApplication()
        let transcript = "F5 completion must arrive in the focused cmux pane"
        var clipboardWrites: [String] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        var insertionAttempts = 0
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.frontmostAppProvider = { cmux }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, block in block() }
        state.asyncDictationInsertionHandlerProvider = {
            { _, _ in
                insertionAttempts += 1
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": transcript])

        XCTAssertEqual(insertionAttempts, 0, "a terminal target must never take the AX path")
        XCTAssertEqual(clipboardWrites, [transcript], "the transcript reaches cmux verbatim on the clipboard")
        XCTAssertTrue(pasteShortcutPosted, "and is delivered by a bracketed Cmd+V")
        XCTAssertEqual(state.confirmationText, transcript)
    }

    /// The regression the cmux test used to guard - a finished F5 transcript
    /// driving exactly one reliable AX insertion that actually renders - still
    /// applies wherever AX is still the delivery path.
    func testF5FinishTranscriptionFiresReliableAXInsertionIntoNonTerminalTarget() {
        let state = VoiceState()
        let editor = FakeRunningApplication(
            bundleIdentifier: "com.example.document-editor",
            processIdentifier: 51515
        )
        let transcript = "F5 completion must arrive in the focused editor"
        var scratchDocument = "draft: "
        var captureCount = 0
        var insertionAttempts = 0
        var clipboardWrites: [String] = []
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.frontmostAppProvider = { editor }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, block in block() }
        state.asyncDictationInsertionHandlerProvider = {
            captureCount += 1
            return { text, completion in
                insertionAttempts += 1
                let strategy = CommandModeAXHelper.insertionStrategy(
                    text: text,
                    focusedValueLength: (scratchDocument as NSString).length,
                    targetBundleIdentifier: editor.bundleIdentifier
                )
                if strategy == .valueRewrite {
                    scratchDocument.append(text)
                }
                completion()
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            XCTFail("a non-terminal target keeps the AX-first path")
            return false
        }

        state.record()
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": transcript])

        XCTAssertEqual(captureCount, 2)
        XCTAssertEqual(insertionAttempts, 1)
        XCTAssertEqual(scratchDocument, "draft: \(transcript)")
        XCTAssertEqual(clipboardWrites, [], "AX delivered it; the clipboard is never touched")
        XCTAssertEqual(state.confirmationText, transcript)
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

    func testSelectedTextStreamingQueuesRemainingChunksWithoutSleepingCaller() {
        var attemptedChunks: [String] = []
        var sleepIntervals: [TimeInterval] = []
        var queuedRemainder: (() -> Void)?
        var completion: AXSelectedTextStreamingDisposition?

        let started = CommandModeAXHelper.beginSelectedTextStreaming(
            for: "abcdefgh",
            maxUTF16Length: 4,
            interChunkDelay: 0.012,
            writeChunk: { chunk in
                attemptedChunks.append(chunk)
                return true
            },
            enqueueRemainder: { queuedRemainder = $0 },
            sleep: { sleepIntervals.append($0) },
            onCompletion: { completion = $0 }
        )

        XCTAssertTrue(started)
        XCTAssertEqual(attemptedChunks, ["abcd"])
        XCTAssertTrue(sleepIntervals.isEmpty)
        XCTAssertNil(completion)

        queuedRemainder?()

        XCTAssertEqual(sleepIntervals, [0.012])
        XCTAssertEqual(attemptedChunks, ["abcd", "efgh"])
        XCTAssertEqual(completion, .applied(writtenChunkCount: 2))
    }

    func testSelectedTextStreamingRejectsFirstChunkSynchronouslyForFallback() {
        var queuedRemainder: (() -> Void)?
        var completion: AXSelectedTextStreamingDisposition?

        let started = CommandModeAXHelper.beginSelectedTextStreaming(
            for: "abcdefgh",
            maxUTF16Length: 4,
            interChunkDelay: 0.012,
            writeChunk: { _ in false },
            enqueueRemainder: { queuedRemainder = $0 },
            sleep: { _ in XCTFail("A rejected first chunk must not sleep") },
            onCompletion: { completion = $0 }
        )

        XCTAssertFalse(started)
        XCTAssertNil(queuedRemainder)
        XCTAssertEqual(completion, .failedBeforeWrite)
    }
}
