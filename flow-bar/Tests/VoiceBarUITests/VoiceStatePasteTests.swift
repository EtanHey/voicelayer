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

        XCTAssertEqual(insertedTexts, ["this is the full transcript ending with wow"])
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

        XCTAssertEqual(insertedTexts, ["paste into the focus that is current on release"])
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

        XCTAssertEqual(insertedTexts, ["this is the full transcript ending with wow"])
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
        scheduled[0].block()

        XCTAssertEqual(scheduled.count, 2)
        scheduled[1].block()

        XCTAssertEqual(insertedTexts, ["fresh transcript"])
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
