import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceStatePasteTests: XCTestCase {
    func testLoadsPersistedRecentTranscriptionsOnInit() {
        let state = VoiceState(
            recentTranscriptionsLoader: {
                [
                    "persisted latest",
                    "persisted older",
                ]
            },
            transcriptionVocabularyLoader: {
                ["VoiceLayer", "Wispr Flow"]
            },
            transcriptionVocabularyAliasLoader: {
                [STTVocabularyAliasPreview(from: "work claude", to: "orcClaude")]
            }
        )

        XCTAssertEqual(state.recentTranscriptions, [
            "persisted latest",
            "persisted older",
        ])
        XCTAssertEqual(state.transcriptionVocabularyTerms, ["VoiceLayer", "Wispr Flow"])
        XCTAssertEqual(state.transcriptionVocabularyAliases, [
            STTVocabularyAliasPreview(from: "work claude", to: "orcClaude"),
        ])
    }

    func testFinalTranscriptionPersistsRecentTranscriptions() {
        var savedSnapshots: [[String]] = []
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { savedSnapshots.append($0) }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "persist this transcript",
        ])

        XCTAssertEqual(savedSnapshots.last, ["persist this transcript"])
    }

    func testFinalTranscriptionDiagnosticsIncludePayloadFingerprintAndPreview() {
        let state = VoiceState()
        var diagnostics: [(String, [String: String])] = []
        state.diagnosticLogger = { event, details in
            diagnostics.append((event, details))
        }

        state.handleEvent([
            "type": "transcription",
            "text": "first line\nmiddle words and a distinctive final tail",
        ])

        let final = diagnostics.first { event, _ in event == "transcription_final" }?.1
        XCTAssertEqual(final?["textLength"], "52")
        XCTAssertEqual(final?["textHead"], "first line\\nmiddle words and a distinctive final tail")
        XCTAssertEqual(final?["textTail"], "first line\\nmiddle words and a distinctive final tail")
        XCTAssertEqual(final?["textFingerprint"]?.count, 16)
    }

    func testFinalTranscriptionHistoryAccessoryRequestsPanelLayoutRefresh() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            transcriptionVocabularyLoader: { [] },
            transcriptionVocabularyAliasLoader: { [] }
        )

        assertVoiceStateEventTriggersPanelLayoutRefresh(
            [
                "type": "transcription",
                "text": "new idle history item",
            ],
            state: state
        )
    }

    func testFinalTranscriptionVocabularyAccessoryRequestsPanelLayoutRefresh() {
        var vocabularyTerms: [String] = []
        var vocabularyAliases: [STTVocabularyAliasPreview] = []
        let state = VoiceState(
            recentTranscriptionsLoader: { ["already visible history"] },
            recentTranscriptionsSaver: { _ in },
            transcriptionVocabularyLoader: { vocabularyTerms },
            transcriptionVocabularyAliasLoader: { vocabularyAliases }
        )
        vocabularyTerms = ["VoiceLayer"]
        vocabularyAliases = [STTVocabularyAliasPreview(from: "work claude", to: "orcClaude")]

        assertVoiceStateEventTriggersPanelLayoutRefresh(
            [
                "type": "transcription",
                "text": "refresh vocabulary",
            ],
            state: state
        )
    }

    func testRecordLeavesModeIdleUntilDaemonStateArrives() {
        let state = VoiceState()
        var sentCommand: [String: Any]?
        var modeObservedInsideSend: VoiceMode?
        var callbackModes: [VoiceMode] = []

        state.sendCommand = { command in
            sentCommand = command
            modeObservedInsideSend = state.mode
        }
        state.onModeChange = { mode in
            callbackModes.append(mode)
        }

        state.record()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(modeObservedInsideSend, .idle)
        XCTAssertTrue(callbackModes.isEmpty)
    }

    func testSnoozeMovesVoiceStateToDisconnected() {
        let state = VoiceState()

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
    }

    func testUnsnoozeReturnsVoiceStateToIdle() {
        let state = VoiceState()
        state.snooze()

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
    }

    func testSnoozeClearsActiveRecordingAudioLevel() throws {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.5)
        _ = try XCTUnwrap(state.audioLevel)

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
        XCTAssertNil(state.audioLevel)
    }

    func testLocalRecordingLevelOverridesSocketLevelWhileRecording() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.15,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.72, accuracy: 0.001)
    }

    func testLocalRecordingLevelIgnoredOutsideRecordingMode() {
        let state = VoiceState()
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.24,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.24, accuracy: 0.001)
    }

    func testStopClearsLocalRecordingLevel() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.72)

        state.cancel()

        XCTAssertNil(state.audioLevel)
    }

    func testCancelDuringRecordingClearsIndicatorToIdleWhenConnected() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.cancel()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.audioLevel)
        XCTAssertFalse(state.speechDetected)
    }

    func testBarInitiatedTranscribingIgnoresStaleIdleUntilTranscriptionArrives() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        XCTAssertEqual(state.mode, .transcribing)
    }

    func testBarInitiatedTranscribingAcceptsRecordingIdleForSuppressedResult() async {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.errorMessage)
    }

    func testRecordingIdleWithoutFinalTranscriptionDoesNotAutoPasteNextTranscript() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordingIdleCleanupClearsPasteIntentEvenIfModeChanges() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "follow-up prompt",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordingIdleBeforeFinalTranscriptionStillAutoPastes() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.pasteConfirmationDelay = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "final text after recording idle",
        ])

        XCTAssertEqual(pastedTexts, ["final text after recording idle"])
    }

    func testLateRecordingStateAfterRecordStartTimeoutStillAutoPastes() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .error)
        XCTAssertNil(state.pendingIntent)

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "late successful dictation",
        ])

        XCTAssertEqual(pastedTexts, ["late successful dictation"])
    }

    func testExpiredLateRecordStartRecoveryDoesNotAutoPasteUnrelatedRecording() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.recordStartLateRecoveryWindow = .milliseconds(20)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later dictation",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    func testFastFinalTranscriptionKeepsBlueStateUntilPendingRecordingIdleCanApply() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0.12
        state.pasteConfirmationDelay = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "fast final transcript",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(pastedTexts, [])

        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(pastedTexts, ["fast final transcript"])
        XCTAssertEqual(state.mode, .idle)
    }

    func testRecordingIdleCleanupDoesNotClearPasteIntentAfterTranscribingResumes() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)
        state.pasteConfirmationDelay = 0
        state.minimumTranscribingDisplayDuration = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "final text after transcribing resumes",
        ])

        XCTAssertEqual(pastedTexts, ["final text after transcribing resumes"])
    }

    func testRepasteUsesStoredTranscript() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "test capture from codex",
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["test capture from codex"])
    }

    func testRepasteLastTranscriptUsesLatestFinalTranscriptInsteadOfCurrentPartial() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "stable final transcript",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "new partial transcript",
            "partial": true,
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["stable final transcript"])
    }

    func testRepasteTranscriptUsesRequestedHistoryItem() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.repasteTranscript("older history item")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["older history item"])
    }

    func testRepasteTranscriptShowsRequestedHistoryItemInConfirmation() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0
        state.transcript = "current unrelated transcript"

        let expectation = expectation(description: "paste invoked")
        state.pasteHandler = { _ in
            expectation.fulfill()
            return true
        }

        state.repasteTranscript("older history item")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(state.confirmationText, "older history item")
    }

    func testCopyTranscriptWritesRequestedHistoryItemToPasteboard() {
        let state = VoiceState()

        var copiedTexts: [String] = []
        state.pasteboardWriter = { copiedTexts.append($0) }

        state.copyTranscript("history item to copy")

        XCTAssertEqual(copiedTexts, ["history item to copy"])
        XCTAssertEqual(state.confirmationText, "Copied")
    }

    func testPartialTranscriptionDoesNotAutoPasteOrConsumeFinalPaste() {
        let state = VoiceState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.sendCommand = { _ in }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "wow",
            "partial": true,
        ])

        XCTAssertEqual(pastedTexts, [])

        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
            "partial": false,
        ])

        XCTAssertEqual(pastedTexts, ["this is the full transcript ending with wow"])
        XCTAssertEqual(state.transcript, "this is the full transcript ending with wow")
    }

    func testAutoPasteUsesRecordedInputInsertionWithoutClipboardFallback() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertEqual(insertedTexts.joined(), "this is the full transcript ending with wow")
        XCTAssertEqual(state.confirmationText, "this is the full transcript ending with wow")
    }

    func testAutoPasteUsesFocusedAXInsertionWhenFocusIsAvailableAtPasteTime() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "paste into the focus that is current on release",
        ])

        XCTAssertEqual(insertedTexts.joined(), "paste into the focus that is current on release")
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "paste into the focus that is current on release")
    }

    func testAutoPasteDoesNotUseClipboardFallbackWhenRecordedInputInsertionFails() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return false
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        // Streaming stops at the first failed chunk (no hammering); only the first
        // word chunk was attempted via AX. No clipboard fallback, retry hint shown.
        XCTAssertEqual(insertedTexts, ["this "])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "Paste failed — click input and press Shift+F5")
    }

    func testAutoPasteDoesNotUseClipboardFallbackWhenNoFocusedInputWasCaptured() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { nil }
        var clipboardWrites: [String] = []
        state.pasteboardWriter = { clipboardWrites.append($0) }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this might not have an input",
        ])

        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "Paste failed — click input and press Shift+F5")
    }

    func testAutoPasteDoesNotTouchClipboardWhenFocusedInsertionIsUnavailable() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { nil }

        var clipboardWrites: [String] = []
        var controlLayerEvents: [(String, [String: String])] = []
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.controlLayerEventWriter = { event, details in
            controlLayerEvents.append((event, details))
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "fresh transcript that must not paste stale clipboard content",
        ])

        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "Paste failed — click input and press Shift+F5")
        XCTAssertTrue(controlLayerEvents.contains { event, details in
            event == "paste_clipboard_fallback_suppressed" &&
                details["reason"] == "transcript_paste_must_not_use_clipboard"
        })
    }

    func testRepasteDoesNotUseClipboardFallbackWhenFocusedInsertionIsUnavailable() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.targetAppActivator = { _ in }

        var clipboardWrites: [String] = []
        var scheduledStepCount = 0

        state.pasteScheduler = { _, block in
            scheduledStepCount += 1
            if scheduledStepCount < 3 {
                block()
            } else {
                XCTFail("repaste should not schedule clipboard work when AX insertion is unavailable")
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }

        state.repasteTranscript("clipboard safety check")

        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "Paste failed — click input and press Shift+F5")
    }

    func testRepasteUsesFocusedAXInsertionWhenAvailable() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.targetAppActivator = { _ in }
        state.pasteConfirmationDelay = 0

        var scheduled: [(delay: TimeInterval, block: () -> Void)] = []
        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []

        state.pasteScheduler = { delay, block in
            scheduled.append((delay, block))
        }
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
        }

        state.repasteTranscript("fresh transcript")

        XCTAssertEqual(scheduled.count, 1)

        // Drain activation + paste-delay + per-chunk streaming steps in order.
        var drained = 0
        while drained < scheduled.count {
            let block = scheduled[drained].block
            drained += 1
            block()
        }

        XCTAssertEqual(insertedTexts.joined(), "fresh transcript")
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "fresh transcript")
    }

    func testAutoPasteFailureUsesGenericMessageInsteadOfAccessibilityBlame() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { { _ in false } }
        var clipboardWrites: [String] = []
        state.pasteboardWriter = { clipboardWrites.append($0) }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(state.confirmationText, "Paste failed — click input and press Shift+F5")
        XCTAssertFalse(state.confirmationText?.contains("Accessibility") ?? true)
    }

    func testRepasteWaitsForMenuFocusToSettle() {
        XCTAssertGreaterThan(VoicePastePlan.repaste.activationDelay, 0)
        XCTAssertEqual(VoicePastePlan.autoPaste.activationDelay, 0)
    }

    // MARK: - Word-by-word paced streaming (cmuxlayer convergence)

    func testWordChunksPreserveSpacingAndConcatenateToOriginal() {
        let text = "stream word by word smoothly"
        let chunks = VoiceState.wordChunks(text)

        XCTAssertEqual(chunks, ["stream ", "word ", "by ", "word ", "smoothly"])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testWordChunksKeepRunsOfSpacesWithPrecedingWord() {
        let text = "hello   world"
        let chunks = VoiceState.wordChunks(text)

        XCTAssertEqual(chunks, ["hello   ", "world"])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testStreamInsertTextEmitsOrderedChunksViaPasteScheduler() {
        let state = VoiceState()
        var scheduled: [() -> Void] = []
        state.pasteScheduler = { _, block in scheduled.append(block) }

        var insertedChunks: [String] = []
        var succeeded = false
        var missed = false

        state.streamInsertText(
            "alpha beta gamma",
            insert: { chunk in
                insertedChunks.append(chunk)
                return true
            },
            onSuccess: { succeeded = true },
            onMiss: { missed = true }
        )

        // Drain the scheduled inter-chunk steps in order.
        while !scheduled.isEmpty {
            let next = scheduled.removeFirst()
            next()
        }

        XCTAssertEqual(insertedChunks, ["alpha ", "beta ", "gamma"])
        XCTAssertEqual(insertedChunks.joined(), "alpha beta gamma")
        XCTAssertTrue(succeeded)
        XCTAssertFalse(missed)
    }

    func testStreamInsertTextStopsAndReportsMissOnMidStreamFailure() {
        let state = VoiceState()
        var scheduled: [() -> Void] = []
        state.pasteScheduler = { _, block in scheduled.append(block) }

        var insertedChunks: [String] = []
        var succeeded = false
        var missed = false

        state.streamInsertText(
            "one two three four",
            insert: { chunk in
                insertedChunks.append(chunk)
                // Fail on the second chunk.
                return insertedChunks.count < 2
            },
            onSuccess: { succeeded = true },
            onMiss: { missed = true }
        )

        while !scheduled.isEmpty {
            let next = scheduled.removeFirst()
            next()
        }

        XCTAssertEqual(insertedChunks, ["one ", "two "])
        XCTAssertTrue(missed)
        XCTAssertFalse(succeeded)
    }

    func testStreamInsertSingleWordInsertsInOneShotWithoutScheduling() {
        let state = VoiceState()
        var scheduleCount = 0
        state.pasteScheduler = { _, block in
            scheduleCount += 1
            block()
        }

        var insertedChunks: [String] = []
        var succeeded = false

        state.streamInsertText(
            "solo",
            insert: { chunk in
                insertedChunks.append(chunk)
                return true
            },
            onSuccess: { succeeded = true },
            onMiss: {}
        )

        XCTAssertEqual(insertedChunks, ["solo"])
        XCTAssertEqual(scheduleCount, 0, "Single-word insert must not pace via scheduler")
        XCTAssertTrue(succeeded)
    }

    func testStreamInsertEmptyTextInsertsOnceWithoutCrash() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }

        var insertedChunks: [String] = []
        var succeeded = false

        state.streamInsertText(
            "",
            insert: { chunk in
                insertedChunks.append(chunk)
                return true
            },
            onSuccess: { succeeded = true },
            onMiss: {}
        )

        XCTAssertEqual(insertedChunks, [""])
        XCTAssertTrue(succeeded)
    }

    func testAutoPasteStreamsMultiWordTranscriptChunkByChunk() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.targetAppActivator = { _ in }
        state.pasteConfirmationDelay = 0

        var scheduled: [() -> Void] = []
        state.pasteScheduler = { _, block in scheduled.append(block) }

        var insertedChunks: [String] = []
        state.dictationInsertionHandlerProvider = {
            { chunk in
                insertedChunks.append(chunk)
                return true
            }
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript",
        ])

        // Drain activation + per-chunk scheduled steps.
        while !scheduled.isEmpty {
            let next = scheduled.removeFirst()
            next()
        }

        XCTAssertEqual(insertedChunks.joined(), "this is the full transcript")
        XCTAssertEqual(insertedChunks, ["this ", "is ", "the ", "full ", "transcript"])
        XCTAssertEqual(state.confirmationText, "this is the full transcript")
    }

    func testRecentTranscriptionsAreMostRecentFirst() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "first note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "second note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "third note",
        ])

        XCTAssertEqual(state.recentTranscriptions, [
            "third note",
            "second note",
            "first note",
        ])
    }
}
