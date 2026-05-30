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

    func testAutoPasteUsesRecordedInputInsertionBeforeClipboardFallback() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertEqual(insertedTexts, ["this is the full transcript ending with wow"])
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertEqual(state.confirmationText, "this is the full transcript ending with wow")
    }

    func testAutoPasteDoesNotUseRecordStartInsertionWhenFocusIsAvailableAtPasteTime() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "paste into the focus that is current on release",
        ])

        XCTAssertEqual(insertedTexts, [])
        XCTAssertEqual(clipboardWrites, ["paste into the focus that is current on release"])
        XCTAssertTrue(pasteShortcutPosted)
        XCTAssertEqual(state.confirmationText, "paste into the focus that is current on release")
    }

    func testAutoPasteFallsBackToClipboardWhenRecordedInputInsertionFails() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var restoredSnapshots: [PasteboardSnapshot] = []
        var pasteShortcutPosted = false
        var pasteboardChangeCount = 7
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return false
            }
        }
        state.pasteboardSnapshotter = {
            PasteboardSnapshot(
                changeCount: pasteboardChangeCount,
                items: [["public.utf8-plain-text": Data("user-copy".utf8)]]
            )
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardChangeCount += 1
        }
        state.pasteboardChangeCountProvider = { pasteboardChangeCount }
        state.pasteboardSnapshotRestorer = {
            restoredSnapshots.append($0)
            pasteboardChangeCount += 1
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertEqual(insertedTexts, ["this is the full transcript ending with wow"])
        XCTAssertEqual(clipboardWrites, ["this is the full transcript ending with wow"])
        XCTAssertEqual(restoredSnapshots, [
            PasteboardSnapshot(
                changeCount: 7,
                items: [["public.utf8-plain-text": Data("user-copy".utf8)]]
            ),
        ])
        XCTAssertTrue(pasteShortcutPosted)
        XCTAssertEqual(state.confirmationText, "this is the full transcript ending with wow")
    }

    func testAutoPasteShowsSuccessTranscriptWhenNoFocusedInputWasCaptured() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { nil }
        state.pasteboardWriter = { _ in }
        state.simulatedPasteHandler = { true }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this might not have an input",
        ])

        XCTAssertEqual(state.confirmationText, "this might not have an input")
    }

    func testAutoPasteSkipsClipboardRestoreIfClipboardChangedAgainAfterWrite() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var restoredSnapshots: [PasteboardSnapshot] = []
        var pasteShortcutPosted = false
        var scheduledRestore: (() -> Void)?
        var pasteboardChangeCount = 3
        var scheduledStepCount = 0

        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return false
            }
        }
        state.pasteScheduler = { _, block in
            scheduledStepCount += 1
            if scheduledStepCount < 3 {
                block()
            } else {
                scheduledRestore = block
            }
        }
        state.pasteboardSnapshotter = {
            PasteboardSnapshot(
                changeCount: pasteboardChangeCount,
                items: [["public.utf8-plain-text": Data("user-copy".utf8)]]
            )
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardChangeCount += 1
        }
        state.pasteboardChangeCountProvider = { pasteboardChangeCount }
        state.pasteboardSnapshotRestorer = {
            restoredSnapshots.append($0)
            pasteboardChangeCount += 1
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "clipboard safety check",
        ])

        XCTAssertEqual(insertedTexts, ["clipboard safety check"])
        XCTAssertEqual(clipboardWrites, ["clipboard safety check"])
        XCTAssertTrue(pasteShortcutPosted)
        XCTAssertNotNil(scheduledRestore)

        // Simulate the user copying something else before our delayed restore fires.
        pasteboardChangeCount += 1
        scheduledRestore?()

        XCTAssertEqual(restoredSnapshots, [])
    }

    func testAutoPasteFailureUsesGenericMessageInsteadOfAccessibilityBlame() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { { _ in false } }
        state.pasteboardWriter = { _ in }
        state.simulatedPasteHandler = { false }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

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
