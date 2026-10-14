@testable import VoiceBarUI
import XCTest

final class SpeakSelectionTests: XCTestCase {
    func testCaptureFailuresHaveSpecificFeedbackAndNeverSpeak() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("capture failure must not speak") }
        for (result, message) in [(SelectionCaptureResult.secureField, "Can't read a secure field"),
                                  (.captureFailed, "Couldn't read the selection, try again"),
                                  (.clipboardRestoreFailed, "Couldn't restore the clipboard"),
                                  (.clipboardChanged, "Couldn't read the selection, try again")] {
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, message)
        }
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

    func testRecordingTranscribingAndF5PreviewIgnoreSelection() {
        let state = VoiceState()
        state.sendCommand = { _ in XCTFail("must not send while dictating") }
        state.selectionTextCaptureHandler = { _ in XCTFail("must not copy while dictating") }
        for mode: VoiceMode in [.recording, .transcribing] { state.mode = mode; state.speakSelection() }
        state.mode = .idle
        state.hotkeyPhase = .pressing
        state.speakSelection()
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
