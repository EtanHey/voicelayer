import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class CommandModeAXHelperTests: XCTestCase {
    func testPrewriteRejectionDeclinesWithoutCompletionOrWrites() {
        for reason in ["ineligible", "missing_snapshot", "invalid_range", "target_changed", "selection_changed"] {
            var reads = 0
            var completions = 0
            var writes = 0
            let started = CommandModeAXHelper.beginSelectionLocalInsertion(
                "ADD שלום 👩‍💻\nsecond line",
                readSnapshot: {
                    reads += 1
                    if reason == "missing_snapshot" { return nil }
                    let location = reason == "invalid_range" ? 99
                        : reason == "selection_changed" && reads > 1 ? 0 : 4
                    return CommandModeSelectionSnapshot(
                        value: "seed", selectedRange: NSRange(location: location, length: 0)
                    )
                },
                isEligible: { reason != "ineligible" },
                isCurrentTarget: { reason != "target_changed" },
                writeSelection: { _ in writes += 1; return true },
                writeCaret: { _ in writes += 1; return true },
                observeSettled: { _ in XCTFail("No observation without a write: \(reason)") },
                completion: { _ in completions += 1 }
            )
            XCTAssertFalse(started, "No setter was invoked: \(reason)")
            XCTAssertEqual(completions, 0, "Declined start has no completion: \(reason)")
            XCTAssertEqual(writes, 0, reason)
        }
    }

    func testNativeEligibilityRequiresEnabledEditableTextAndRejectsSecureOrChangedIdentity() {
        for reason in ["editable", "explicit_editable", "disabled", "unknown_enabled", "readonly", "file_list", "secure", "protected", "identity_changed"] {
            let eligibility = CommandModeAXHelper.typingEligibility(
                processIdentifier: 51515, role: reason == "file_list" ? "AXOutline" : "AXTextField",
                subrole: reason == "secure" ? "AXSecureTextField" : nil,
                enabled: reason == "unknown_enabled" ? nil : reason != "disabled",
                editable: reason == "readonly" ? false : reason == "explicit_editable" ? true : nil,
                selectedTextSettable: false, valueSettable: reason != "explicit_editable",
                protectedContent: reason == "protected", matchesCurrentFocus: { reason != "identity_changed" }
            )
            XCTAssertEqual(eligibility.permitsTyping(into: 51515),
                           ["editable", "explicit_editable"].contains(reason), reason)
            XCTAssertFalse(eligibility.permitsTyping(into: 62626), reason)
        }
    }

    func testNativePrewriteDeclineAllowsOneEligibleSettingsHistoryDelivery() {
        let state = VoiceState()
        let editor = FakeRunningApplication(bundleIdentifier: "com.example.Editor", processIdentifier: 51515)
        let text = "ADD שלום 👩‍💻\nsecond line"
        var typed: [String] = []
        var completions = 0
        state.frontmostAppProvider = { editor }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, work in work() }
        state.focusedTargetEligibilityProvider = {
            CommandModeAXHelper.typingEligibility(
                processIdentifier: 51515, role: "AXTextField", subrole: nil, enabled: true, editable: nil,
                selectedTextSettable: false, valueSettable: true, protectedContent: false,
                matchesCurrentFocus: { true }
            )
        }
        state.asyncDictationInsertionHandlerProvider = { { text, completion in
            CommandModeAXHelper.beginSelectionLocalInsertion(
                text, readSnapshot: { nil }, isEligible: { true }, isCurrentTarget: { true },
                writeSelection: { _ in XCTFail("Pre-write rejection"); return false },
                writeCaret: { _ in XCTFail("No caret write"); return false },
                observeSettled: { _ in XCTFail("No dispatch") },
                completion: { completions += 1; completion($0) }
            )
        } }
        state.textTypingHandler = { typed.append($0); return true }
        state.pasteboardWriter = { _ in XCTFail("Keep clipboard") }
        state.repasteTranscript(text, source: "settings_history")
        XCTAssertEqual(typed, [text])
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(state.confirmationText?.contains("Insertion unverified") == true)
    }

    private func localInsertion(
        text: String = "ADD",
        value: String = "seed\n\n",
        range: NSRange = NSRange(location: 6, length: 0),
        acceptsCaret: Bool = true,
        settledRange: NSRange? = nil,
        readable: Bool = true,
        mismatchedReadback: Bool = false,
        eligible: Bool = true
    ) -> (DictationInsertionResult?, CommandModeSelectionSnapshot, Int) {
        var document = CommandModeSelectionSnapshot(value: value, selectedRange: range)
        var writes = 0
        var result: DictationInsertionResult?
        var settled: (() -> Void)?
        let started = CommandModeAXHelper.beginSelectionLocalInsertion(
            text,
            readSnapshot: {
                if writes > 0, !readable { return nil }
                if writes > 0, mismatchedReadback { return CommandModeSelectionSnapshot(value: "stale", selectedRange: document.selectedRange) }
                return document
            },
            isEligible: { eligible },
            isCurrentTarget: { true },
            writeSelection: {
                writes += 1
                document.value = (document.value as NSString).replacingCharacters(in: document.selectedRange, with: $0)
                return true
            },
            writeCaret: { document.selectedRange = acceptsCaret ? $0 : NSRange(location: 0, length: 0); return acceptsCaret },
            observeSettled: { settled = $0 },
            completion: { result = $0 }
        )
        XCTAssertEqual(started, eligible, "Only an attempted write consumes insertion")
        if let settledRange { document.selectedRange = settledRange }
        settled?()
        return (result, document, writes)
    }

    func testAcceptedValueWriteWithRejectedCaretIsUnverifiedWithoutRetyping() {
        let (result, document, writes) = localInsertion(acceptsCaret: false)
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(document.value, "seed\n\nADD")
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(writes, 1)
    }

    func testCaretResetAfterAcceptedSetterIsUnverifiedWithoutRetyping() {
        let (result, document, writes) = localInsertion(settledRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(document.value, "seed\n\nADD")
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(writes, 1)
    }

    func testSelectionLocalInsertionPreservesBlankLinesAndUTF16Replacement() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        for range in [NSRange(location: 13, length: 0), NSRange(location: 7, length: 5)] {
            let (result, document, writes) = localInsertion(text: text, value: "alpha\n\nbeta.\n", range: range)
            let expected = range.length == 0 ? "alpha\n\nbeta.\n\(text)" : "alpha\n\n\(text)\n"
            XCTAssertEqual(document.value, expected)
            XCTAssertEqual(document.selectedRange, NSRange(location: range.location + text.utf16.count, length: 0))
            XCTAssertEqual(result, .verified)
            XCTAssertEqual(writes, 1)
        }
    }

    func testMissingOrMismatchedReadbackCannotVerifyOrRetryAppliedText() {
        for (readable, mismatch) in [(false, false), (true, true)] {
            let (result, document, writes) = localInsertion(readable: readable, mismatchedReadback: mismatch)
            XCTAssertEqual(result, .appliedUnverified)
            XCTAssertEqual(document.value, "seed\n\nADD")
            XCTAssertEqual(writes, 1)
        }
    }

    func testValueSetterErrorWithMatchingReadbackDoesNotRetype() {
        var document = CommandModeSelectionSnapshot(value: "seed\n\n", selectedRange: NSRange(location: 6, length: 0))
        var result: DictationInsertionResult?
        var writes = 0
        let started = CommandModeAXHelper.beginSelectionLocalInsertion(
            "ADD", readSnapshot: { document }, isEligible: { true }, isCurrentTarget: { true },
            writeSelection: { _ in writes += 1; document.value += "ADD"; document.selectedRange.location = 9; return false },
            writeCaret: { _ in XCTFail("Do not move caret after setter error"); return false },
            observeSettled: { _ in XCTFail("No second write or retry") }, completion: { result = $0 }
        )
        XCTAssertTrue(started)
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(document.value, "seed\n\nADD")
        XCTAssertEqual(writes, 1)
    }

    func testSetterErrorWithUnchangedReadbackIsStillUnverified() {
        var result: DictationInsertionResult?
        CommandModeAXHelper.beginSelectionLocalInsertion(
            "ADD", readSnapshot: { CommandModeSelectionSnapshot(value: "seed\n\n", selectedRange: NSRange(location: 6, length: 0)) },
            isEligible: { true }, isCurrentTarget: { true }, writeSelection: { _ in false },
            writeCaret: { _ in XCTFail("No caret write after rejected setter"); return false },
            observeSettled: { _ in XCTFail("No retry") }, completion: { result = $0 }
        )
        XCTAssertEqual(result, .appliedUnverified, "A setter may apply later despite an immediate error")
    }

    func testSelectionChangeBeforeDispatchReceivesNoWrite() {
        var reads = 0
        var result: DictationInsertionResult?
        CommandModeAXHelper.beginSelectionLocalInsertion(
            "ADD", readSnapshot: {
                reads += 1
                return CommandModeSelectionSnapshot(value: "seed\n\n", selectedRange: NSRange(location: reads == 1 ? 6 : 0, length: 0))
            }, isEligible: { true }, isCurrentTarget: { true },
            writeSelection: { _ in XCTFail("Do not write after selection changes"); return false },
            writeCaret: { _ in XCTFail("Do not move caret"); return false },
            observeSettled: { _ in XCTFail("No dispatch") }, completion: { result = $0 }
        )
        XCTAssertNil(result, "A pre-write rejection declines without completing")
    }

    func testEmptyT3ComposerWithSettledCaretAtOpeningIsUnverified() {
        let (result, document, writes) = localInsertion(text: String(repeating: "a", count: 875), value: "",
                                                      range: NSRange(location: 0, length: 0),
                                                      settledRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(document.value.utf16.count, 875)
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(writes, 1)
    }

    func testHeliumGeminiCorrectAppendWithResetCaretIsUnverified() {
        let (result, document, writes) = localInsertion(value: "Well seed.\n\n", range: NSRange(location: 12, length: 0),
                                                      settledRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(document.value, "Well seed.\n\nADD")
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(writes, 1)
    }

    func testUncertifiedRichTargetReceivesNoWriteAndPreservesNodeIdentity() {
        let nodes = ["text:alpha", "screenshot:fixture-image-1", "break", "text:beta.", "break"]
        let strategy = CommandModeAXHelper.insertionStrategy(text: "ADD", focusedValueLength: 64, targetBundleIdentifier: "com.t3tools.t3code")
        let (result, document, writes) = localInsertion(value: nodes.joined(separator: "\n"), eligible: strategy == .selectionLocal)
        XCTAssertNil(result, "Ineligible targets decline without completing")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(document.value.components(separatedBy: "\n"), nodes)
        // Withholding unsafe delivery proves preservation, not native insertion acceptance.
    }

    func testHeliumRichHostRequiresNativeProofEvenWithoutWebAreaMetadata() {
        XCTAssertEqual(CommandModeAXHelper.insertionStrategy(text: "ADD", focusedValueLength: 12,
                                                            targetBundleIdentifier: "net.imput.helium"), .requiresNativeProof)
    }

    func testFocusChangeAfterWriteDoesNotMoveCaretOrRetry() {
        var focused = true
        var writes = 0
        var result: DictationInsertionResult?
        CommandModeAXHelper.beginSelectionLocalInsertion(
            "ADD", readSnapshot: { CommandModeSelectionSnapshot(value: "seed\n\n", selectedRange: NSRange(location: 6, length: 0)) },
            isEligible: { true }, isCurrentTarget: { focused },
            writeSelection: { _ in writes += 1; focused = false; return true },
            writeCaret: { _ in XCTFail("Never change selection after focus moves"); return false },
            observeSettled: { $0() }, completion: { result = $0 }
        )
        XCTAssertEqual(result, .appliedUnverified)
        XCTAssertEqual(writes, 1)
    }

    func testT3RichComposerMustNotSelectWholeValueRewrite() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: "ADD שלום 👩‍💻",
            focusedValueLength: 64,
            targetBundleIdentifier: "com.t3tools.t3code"
        )
        XCTAssertNotEqual(strategy, .valueRewrite,
                          "A plain string cannot certify rich-node and boundary preservation")
    }

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

    func testVeryLongNonterminalInsertionUsesSelectionLocalPlan() {
        let strategy = CommandModeAXHelper.insertionStrategy(
            text: String(repeating: "very long transcript chunk ", count: 500),
            focusedValueLength: 120_000,
            targetBundleIdentifier: "com.example.document-editor"
        )

        XCTAssertEqual(
            strategy,
            .selectionLocal
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
    /// which path a finished F5 transcript takes to get there. Since 2026-09-13 that
    /// path is TYPING, never the clipboard: dictation must not touch the
    /// pasteboard (Etan's spec — see VoiceState's paste call site).
    func testF5FinishTranscriptionReachesCmuxByTypingNotTheClipboard() {
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
        var typed: [String] = []
        state.textTypingHandler = { text in
            typed.append(text)
            return true
        }

        state.record()
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": transcript])

        XCTAssertEqual(insertionAttempts, 0, "a terminal target must never take the AX path")
        XCTAssertEqual(clipboardWrites, [], "dictation must never write the pasteboard")
        XCTAssertFalse(pasteShortcutPosted, "and never posts Cmd+V")
        XCTAssertEqual(typed, [transcript], "the transcript is typed into cmux verbatim")
        XCTAssertEqual(state.confirmationText, transcript)
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
    }

    /// The regression the cmux test used to guard - a finished F5 transcript
    /// driving exactly one reliable AX insertion that actually renders - still
    /// applies wherever AX is still the delivery path.
    ///
    /// The original wrapped its insertion in an `insertionStrategy` call because
    /// cmux accepts selected-text AX writes without rendering them, so only the
    /// atomic value rewrite was visible. That simulation is deliberately NOT
    /// carried over: for this fixture the strategy resolves to `.valueRewrite`
    /// for any bundle id on length alone, so the branch would gate nothing while
    /// reading as coverage it is not. The cmux atomic override is a pure
    /// function and is pinned as one by
    /// `testVeryLongCmuxTerminalInsertionUsesSingleValueRewritePlan` — the only
    /// test whose lengths force `.selectedTextStreaming` without it.
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
                scratchDocument.append(text)
                completion(.verified)
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
