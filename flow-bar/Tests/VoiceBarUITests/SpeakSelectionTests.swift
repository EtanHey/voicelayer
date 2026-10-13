@testable import VoiceBarUI
import XCTest

final class SpeakSelectionTests: XCTestCase {
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
            state.selectionTextCaptureHandler = { $0(selection) }
            state.speakSelection()
            XCTAssertEqual(state.confirmationText, "No text selected")
            XCTAssertFalse(state.isCollapsed, "transient feedback must be visible from collapsed idle")
            XCTAssertEqual(state.mode, .idle)
        }
    }

    func testPendingCaptureCannotOverlapOrInterruptNewDictation() {
        let state = VoiceState()
        var completion: ((String?) -> Void)?
        var captures = 0
        state.sendCommand = { _ in XCTFail("stale capture must not speak over dictation") }
        state.selectionTextCaptureHandler = { captures += 1; completion = $0 }
        state.speakSelection()
        state.speakSelection()
        XCTAssertEqual(captures, 1)
        state.mode = .recording
        completion?("selection")
        XCTAssertEqual(state.mode, .recording)
    }
}
