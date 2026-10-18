@testable import VoiceBarUI
import XCTest

final class SpeakSelectionTests: XCTestCase {
    func testBusyRequestEndsWithItsSessionAndCannotReappearInANewSession() {
        for (mode, phase) in [(VoiceMode.recording, HotkeyPhase.idle), (.transcribing, .idle),
                              (.idle, .pressing), (.idle, .holding), (.idle, .awaitingSecondTap)] {
            for endMode in [VoiceMode.idle, .speaking, .disconnected, .error] {
                let state = VoiceState()
                state.mode = mode
                state.hotkeyPhase = phase
                state.transcript = "Keep every synthetic word שלום 👩‍💻"
                state.sendCommand = { _ in XCTFail("UI cleanup must send no command") }
                state.selectionTextCaptureHandler = { _ in XCTFail("UI cleanup must not capture") }
                state.speakSelection()
                XCTAssertTrue(state.showsSelectionBusyNote)
                state.hotkeyPhase = .idle
                state.mode = endMode
                XCTAssertFalse(state.showsSelectionBusyNote, "Session ended: \(mode)/\(phase) → \(endMode)")
                state.mode = .idle
                state.hotkeyPhase = .pressing
                XCTAssertNil(VoiceBarPresentation.selectionBusyNote(isRequested: state.showsSelectionBusyNote,
                    mode: state.mode, hotkeyPhase: state.hotkeyPhase), "No new Option+F5 request")
                state.hotkeyPhase = .idle
                state.mode = .recording
                XCTAssertFalse(state.showsSelectionBusyNote, "A new recording must not inherit the request")
                XCTAssertEqual(state.transcript, "Keep every synthetic word שלום 👩‍💻")
            }
        }
    }

    @MainActor
    func testAnEndedSessionTimerCannotClearANewBusyRequest() async throws {
        let state = VoiceState()
        state.mode = .recording
        state.sendCommand = { _ in XCTFail("UI timers must send no command") }
        state.selectionTextCaptureHandler = { _ in XCTFail("UI timers must not capture") }
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        state.mode = .idle
        XCTAssertFalse(state.showsSelectionBusyNote)
        state.mode = .recording
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(state.showsSelectionBusyNote, "Old timer must not clear the new request")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .recording)
    }

    func testCaptureFailuresHaveSpecificFeedbackAndNeverSpeak() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("capture failure must not speak") }
        for (result, message) in [(SelectionCaptureResult.secureField, "Can't read a secure field"),
                                  (.captureFailed, "Couldn't read the selection, try again"),
                                  (.clipboardRestoreFailed, "Couldn't restore the clipboard"),
                                  (.copyTimedOut, "Timed out\nReselect"),
                                  (.copyEmpty, "No text\nReselect"),
                                  (.copyFailed, "Can't copy\nCheck A11y"),
                                  (.clipboardChanged, "Clipboard\nReselect")] {
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, message)
        }
    }

    func testDiagnosticsContainOnlyMetadataAndForwardTheFullSelectionOnce() {
        let state = VoiceState()
        let text = "PRIVATE_SELECTION שלום👩🏽‍💻\n\n  tail…  "
        var events: [(String, [String: String])] = []
        var commands: [[String: Any]] = []
        state.diagnosticLogger = { events.append(($0, $1)) }
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text).observed(axRead: .empty, path: .copy)) }
        state.speakSelection()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["text"] as? String, text)
        XCTAssertEqual(commands.first?["source"] as? String, "selection")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "selection_capture")
        let details = events.first?.1 ?? [:]
        XCTAssertEqual(Set(details.keys), Set(["outcome", "ax_read", "path", "host_structure", "appKeyWindowTitle",
            "utf16_count", "line_breaks", "tabs", "object_replacements", "list_marker_lines", "pipe_lines",
            "copy_attempted", "copy_resolution"]))
        XCTAssertEqual(details["appKeyWindowTitle"], "not_recorded")
        XCTAssertFalse(details.values.contains { $0.contains("PRIVATE_SELECTION") || $0.contains("שלום") })
    }

    func testSecondPressCancelsPendingCaptureAndAFreshPressCanCaptureAgain() {
        let state = VoiceState()
        var completion: ((SelectionCaptureResult) -> Void)?
        var captures = 0
        var commands = 0
        state.sendCommand = { _ in commands += 1 }
        state.selectionTextCaptureHandler = { captures += 1; completion = $0 }
        state.speakSelection()
        state.speakSelection()
        XCTAssertEqual(captures, 1)
        completion?(.completed("text from cancelled capture"))
        XCTAssertEqual(commands, 0)
        XCTAssertNil(state.confirmationText)
        state.speakSelection()
        XCTAssertEqual(captures, 2)
        completion?(.completed("fresh selection"))
        XCTAssertEqual(commands, 1)
    }

    private func speakingState(_ text: String = "old selection", preparing: Bool = false) -> VoiceState {
        let state = VoiceState()
        state.isConnected = true
        state.handleEvent(["type": "state", "state": "speaking", "text": preparing ? "Preparing speech…" : text,
                           "long_read": ["id": "old-read", "preparing": preparing]])
        return state
    }

    func testDifferentSelectionReplacesSpeakingAndPreparingWithoutGlobalStop() {
        for preparing in [false, true] {
            let state = speakingState(preparing: preparing)
            let text = "NEW private selection שלום 👩‍💻\n\n  tail…  "
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "speak_text")
            XCTAssertEqual(commands.first?["text"] as? String, text)
            XCTAssertEqual(commands.first?["source"] as? String, "selection")
        }
    }

    func testExternalPreparingTreatsEveryNonemptySelectionAsDifferentIncludingThePlaceholder() {
        for text in ["read this instead", "Preparing speech…"] {
            let state = speakingState(preparing: true)
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.selectionTextCaptureHandler = { $0(.completed(text)) }
            state.speakSelection()
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "speak_text")
            XCTAssertEqual(commands.first?["text"] as? String, text)
        }
    }

    func testOwnPreparingUsesKnownInputForBothSameAndDifferentSelections() {
        for next in ["Preparing speech…", "different selection"] {
            let state = VoiceState()
            var commands: [String] = []
            var selection = "Preparing speech…"
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { $0(.completed(selection)) }
            state.speakSelection()
            state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                               "long_read": ["id": "own-preparing", "preparing": true]])
            selection = next
            state.speakSelection()
            XCTAssertEqual(commands, ["speak_text", next == "Preparing speech…" ? "stop" : "speak_text"])
        }
    }

    func testExternalSpeakingWithoutCanonicalTextUsesUnknownTextRulesEvenWithSubtitleWords() {
        for (result, expected) in [(SelectionCaptureResult.completed("same"), "speak_text"),
                                   (.completed(nil), "stop"), (.captureFailed, "stop")] {
            let state = VoiceState()
            state.handleEvent(["type": "state", "state": "speaking"])
            state.handleEvent(["type": "subtitle", "words": [["text": "same", "offset_ms": 0, "duration_ms": 100]]])
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertEqual(commands, [expected], "Subtitle tokens are not canonical input text")
        }
    }

    func testExternalTextBecomingKnownDuringCaptureIsUsedForComparison() {
        let state = speakingState(preparing: true)
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "now known text",
                           "long_read": ["id": "old-read", "preparing": false]])
        completion?(.completed("now  known\ntext"))
        XCTAssertEqual(commands, ["stop"])
    }

    func testSameSelectionWithNormalizedWhitespaceStops() {
        let state = speakingState("same  selection\nשלום")
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("  same\tselection שלום\n")) }
        state.speakSelection()
        XCTAssertEqual(commands, ["stop"])
    }

    func testSameRawSelectionStopsDuringPreparationAndAfterMarkdownProjection() {
        let state = VoiceState()
        let text = "# Private title\n\n- original selection"
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed(text)) }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "own-read", "preparing": true]])
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
        // A new read must retain the original selection even though its display is projected.
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "next-read", "preparing": true]])
        state.handleEvent(["type": "state", "state": "speaking", "text": "Private title original selection",
                           "long_read": ["id": "next-read", "preparing": false]])
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
    }

    func testEmptyAndFailedCapturesStopSpeakingAndPreparing() {
        for preparing in [false, true] {
            for result in [SelectionCaptureResult.completed(nil), .completed(" \n\t"), .copyTimedOut,
                           .secureField, .captureFailed, .clipboardRestoreFailed, .clipboardChanged, .copyFailed, .copyEmpty] {
                let state = speakingState(preparing: preparing)
                var commands: [String] = []
                var captures = 0
                state.sendCommand = { commands.append($0["cmd"] as! String) }
                state.selectionTextCaptureHandler = { captures += 1; $0(result) }
                state.speakSelection()
                XCTAssertEqual(captures, 1)
                XCTAssertEqual(commands, ["stop"])
            }
        }
    }

    func testReplacementBusyAckHasVisibleTransientFeedbackWithoutStoppingOldRead() {
        let state = speakingState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        let id = commands.first?["id"] as? String ?? "missing-selection-id"
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy", "id": id])
        XCTAssertTrue(state.showsSelectionBusyNote)
        XCTAssertEqual(state.selectionFeedbackNote, "Busy. Selection not read")
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text"])
    }

    func testRejectedRequestCannotDonateItsInputToAnExternalReadArrivingBeforeTheAck() {
        let state = speakingState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("rejected input")) }
        state.speakSelection()
        let id = commands.first?["id"] as? String ?? "missing"
        state.handleEvent(["type": "state", "state": "speaking", "text": "external text",
                           "long_read": ["id": "external-read", "preparing": false]])
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy", "id": id])
        state.selectionTextCaptureHandler = { $0(.completed("external text")) }
        state.speakSelection()
        XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
    }

    func testNonBusyRejectionDoesNotClaimVoiceLayerIsBusyOrExposeDaemonDetails() {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject",
                           "reason": "private daemon error details", "id": request["id"] as? String ?? "missing"])
        XCTAssertEqual(state.selectionFeedbackNote, "Selection not read. Try again")
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
    }

    func testSecondPressStopsAndLateOrDuplicateCallbackCannotReplaceAFreshRead() {
        let state = speakingState()
        var callbacks: [(SelectionCaptureResult) -> Void] = []
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { callbacks.append($0) }
        state.speakSelection()
        XCTAssertTrue(commands.isEmpty, "capture comes before Stop")
        state.speakSelection()
        XCTAssertEqual(commands, ["stop"])
        guard let old = callbacks.first else { return XCTFail("missing capture") }
        old(.completed("stale selection"))
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.speakSelection()
        old(.completed("duplicate stale callback"))
        callbacks.last?(.completed("fresh selection"))
        XCTAssertEqual(commands, ["stop", "speak_text"])
    }

    func testStopAndDictationInvalidateCaptureEvenIfTheyFinishBeforeItReturns() {
        for interrupt in ["stop", "dictation", "f5", "disconnect"] {
            let state = speakingState()
            var completion: ((SelectionCaptureResult) -> Void)?
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as! String) }
            state.selectionTextCaptureHandler = { completion = $0 }
            state.speakSelection()
            switch interrupt {
            case "stop": state.stop()
            case "dictation": state.mode = .recording
            case "f5": state.hotkeyPhase = .pressing; state.hotkeyPhase = .idle
            default: state.mode = .disconnected
            }
            state.mode = .idle
            completion?(.completed("stale selection"))
            XCTAssertFalse(commands.contains("speak_text"), interrupt)
        }
    }

    func testPreparationToPlaybackOfSameReadDoesNotDiscardReplacementCapture() {
        let state = speakingState(preparing: true)
        var completion: ((SelectionCaptureResult) -> Void)?
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "old selection",
                           "long_read": ["id": "old-read", "preparing": false]])
        completion?(.completed("new selection"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testSelectionCanRetryFromErrorButANewErrorInvalidatesAnOlderCapture() {
        let state = VoiceState()
        state.mode = .error
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("retry selection")) }
        state.speakSelection()
        XCTAssertEqual(commands, ["speak_text"])
        state.mode = .idle
        var completion: ((SelectionCaptureResult) -> Void)?
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.mode = .error
        state.mode = .idle
        completion?(.completed("stale selection"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testAnotherReadSupersedingCaptureWins() {
        let state = speakingState()
        var completion: ((SelectionCaptureResult) -> Void)?
        state.sendCommand = { _ in XCTFail("old capture cannot replace a newer read") }
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "new owner",
                           "long_read": ["id": "new-read", "preparing": false]])
        completion?(.completed("stale selection"))
    }

    @MainActor
    func testLatestCaptureSurvivesPendingSubmissionsFirstReceipt() async throws {
        for ackBeforeReceipt in [false, true] {
            for (result, expected) in [(SelectionCaptureResult.completed("pending B"), "stop"),
                                       (.completed("different C"), "speak_text"),
                                       (.completed(nil), "stop"), (.copyTimedOut, "stop"), (.captureFailed, "stop")] {
                let state = speakingState("playing A")
                var commands: [[String: Any]] = []
                state.sendCommand = { commands.append($0) }
                state.selectionTextCaptureHandler = { $0(.completed("pending B")) }
                state.speakSelection()
                let id = try XCTUnwrap(commands.first?["id"] as? String)
                var completion: ((SelectionCaptureResult) -> Void)?
                state.selectionTextCaptureHandler = { completion = $0 }
                state.speakSelection()
                await Task.yield()
                if ackBeforeReceipt {
                    state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "accept", "id": id])
                }
                state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                                   "long_read": ["id": "pending-read-B", "preparing": true]])
                await Task.yield()
                try XCTUnwrap(completion)(result)
                XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", expected],
                               "ackBeforeReceipt=\(ackBeforeReceipt), outcome=\(result.outcome)")
                if expected == "speak_text" { XCTAssertEqual(commands.last?["text"] as? String, "different C") }
            }
        }
    }

    func testUnrelatedReadStillInvalidatesLatestCaptureWhileSubmissionIsPending() {
        let state = speakingState("playing A")
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { $0(.completed("pending B")) }
        state.speakSelection()
        var completion: ((SelectionCaptureResult) -> Void)?
        state.selectionTextCaptureHandler = { completion = $0 }
        state.speakSelection()
        state.handleEvent(["type": "state", "state": "speaking", "text": "unrelated D",
                           "long_read": ["id": "unrelated-read-D", "preparing": false]])
        completion?(.completed("stale C"))
        XCTAssertEqual(commands, ["speak_text"])
    }

    func testDaemonRejectionNoteSurvivesSpeakingRebroadcastAndChunkChange() throws {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": try XCTUnwrap(request["id"] as? String)])
        for readID in ["old-read", "next-chunk-read"] {
            state.handleEvent(["type": "state", "state": "speaking", "text": "ongoing speech",
                               "long_read": ["id": readID, "preparing": false]])
            XCTAssertEqual(state.selectionFeedbackNote, "Busy. Selection not read")
        }
    }

    func testSameSelectionStopsBeforePreparationReceiptAndOldAckIsIgnored() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.selectionTextCaptureHandler = { $0(.completed("own selection")) }
        state.speakSelection()
        state.speakSelection()
        XCTAssertEqual(commands.compactMap { $0["cmd"] as? String }, ["speak_text", "stop"])
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": commands.first?["id"] as? String ?? "missing"])
        XCTAssertFalse(state.showsSelectionBusyNote)
    }

    @MainActor
    func testDaemonBusyNoteExpiresWithoutChangingPlayback() async throws {
        let state = speakingState()
        var request: [String: Any] = [:]
        state.sendCommand = { request = $0 }
        state.selectionTextCaptureHandler = { $0(.completed("new selection")) }
        state.speakSelection()
        state.handleEvent(["type": "ack", "command": "speak_text", "outcome": "reject", "reason": "busy",
                           "id": request["id"] as? String ?? "missing"])
        XCTAssertTrue(state.showsSelectionBusyNote)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .speaking)
        XCTAssertEqual(state.statusText, "old selection")
    }

    func testBusySelectionReportsReasonWithoutChangingDictationOrCapturing() {
        for (mode, phase, reason) in [(VoiceMode.recording, HotkeyPhase.idle, "recording"),
                                      (.transcribing, .idle, "transcribing"),
                                      (.idle, .pressing, "f5_preview"),
                                      (.idle, .holding, "f5_preview"),
                                      (.idle, .awaitingSecondTap, "f5_preview")] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                                   recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
            state.mode = mode
            state.hotkeyPhase = phase
            state.transcript = "Synthetic words still being dictated שלום…"
            state.confirmationText = "Full previous transcript remains recoverable"
            state.recordingMode = "ptt"
            if mode == .recording { state.handleEvent(["type": "audio_level", "rms": 0.6]) }
            let previousMode = state.previousMode
            let captureLive = state.captureLive
            let waveform = state.recordingWaveformLevels
            let transcript = state.transcript
            var captures = 0
            var commands = 0
            var events: [(String, [String: String])] = []
            state.sendCommand = { _ in commands += 1 }
            state.selectionTextCaptureHandler = { _ in captures += 1 }
            state.diagnosticLogger = { events.append(($0, $1)) }
            state.speakSelection()
            XCTAssertEqual(events.count, 1, reason)
            XCTAssertEqual(events.first?.0, "selection_busy", reason)
            XCTAssertEqual(events.first?.1["reason"], reason)
            XCTAssertEqual(events.first?.1["appKeyWindowTitle"], "not_recorded")
            XCTAssertEqual(captures, 0, "no capture means no Copy event")
            XCTAssertEqual(commands, 0, "no speech, Stop or recorder command")
            XCTAssertEqual(state.mode, mode)
            XCTAssertEqual(state.previousMode, previousMode)
            XCTAssertEqual(state.hotkeyPhase, phase)
            XCTAssertEqual(state.transcript, transcript)
            XCTAssertEqual(state.recordingMode, "ptt")
            XCTAssertEqual(state.captureLive, captureLive)
            XCTAssertEqual(state.recordingWaveformLevels, waveform)
            XCTAssertEqual(state.confirmationText, "Full previous transcript remains recoverable")
            XCTAssertEqual(Set(events.first?.1.keys.map { $0 } ?? []), Set(["reason", "appKeyWindowTitle"]))
        }
    }

    @MainActor
    func testBusyNoteExpiresAndARepeatedPressRestartsItsTwoSeconds() async throws {
        let state = VoiceState()
        state.mode = .recording
        state.transcript = "Keep every synthetic word"
        state.handleEvent(["type": "audio_level", "rms": 0.6])
        state.sendCommand = { _ in XCTFail("busy expiry must not send commands") }
        state.selectionTextCaptureHandler = { _ in XCTFail("busy expiry must not capture") }
        state.speakSelection()
        XCTAssertTrue(state.showsSelectionBusyNote)
        try await Task.sleep(for: .milliseconds(1100))
        state.speakSelection()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(state.showsSelectionBusyNote, "an old timer must not clear the repeated note early")
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(state.showsSelectionBusyNote)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertTrue(state.captureLive)
        XCTAssertEqual(state.transcript, "Keep every synthetic word")
    }

    func testBusyNoteDoesNotInterceptTheExistingStopAction() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        var commands: [String] = []
        state.sendCommand = { commands.append($0["cmd"] as! String) }
        state.selectionTextCaptureHandler = { _ in XCTFail("busy note must not capture") }
        state.speakSelection()
        XCTAssertTrue(commands.isEmpty)
        state.stop()
        XCTAssertEqual(commands, ["stop"])
        XCTAssertEqual(state.mode, .transcribing)
    }

    func testEmptySelectionUsesExistingTransientConfirmation() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("empty selection must not speak") }
        state.isCollapsed = true
        for selection: String? in [nil, "", " \n\t "] {
            state.selectionTextCaptureHandler = { $0(.completed(selection)) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, "No text selected")
            XCTAssertFalse(state.isCollapsed, "transient feedback must be visible from collapsed idle")
            XCTAssertEqual(state.mode, .idle)
        }
    }

    func testCaptureCompletionCannotInterruptNewDictation() {
        let state = VoiceState()
        var completion: ((SelectionCaptureResult) -> Void)?
        var captures = 0
        state.sendCommand = { _ in XCTFail("stale capture must not speak over dictation") }
        state.selectionTextCaptureHandler = { captures += 1; completion = $0 }
        state.speakSelection()
        XCTAssertEqual(captures, 1)
        state.mode = .recording
        completion?(.completed("selection"))
        XCTAssertEqual(state.mode, .recording)
    }
}
