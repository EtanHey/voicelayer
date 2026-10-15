@testable import VoiceBarUI
import XCTest

final class SpeakSelectionTests: XCTestCase {
    func testCaptureFailuresHaveSpecificFeedbackAndNeverSpeak() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("capture failure must not speak") }
        for (result, message) in [(SelectionCaptureResult.secureField, "Can't read a secure field"),
                                  (.captureFailed, "Couldn't read the selection, try again"),
                                  (.clipboardRestoreFailed, "Couldn't restore the clipboard"),
                                  (.copyTimedOut, "Copy timed out. Select text and try again"),
                                  (.copyEmpty, "Copy returned no text. Select text and try again"),
                                  (.copyFailed, "Couldn't copy. Check Accessibility and try again"),
                                  (.clipboardChanged, "Clipboard changed. Select the text and try again")] {
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
                                             "utf16_count", "line_breaks", "tabs", "object_replacements", "list_marker_lines", "pipe_lines"]))
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

    func testSpeakingStopsWithoutCapturing() {
        let state = VoiceState()
        state.mode = .speaking
        state.selectionTextCaptureHandler = { _ in XCTFail("stop must not capture") }
        var commands: [[String: String]] = []
        state.sendCommand = { commands.append($0 as! [String: String]) }
        state.speakSelection()
        XCTAssertEqual(commands, [["cmd": "stop"]])
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
