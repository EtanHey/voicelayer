import XCTest
@testable import VoiceBarUI

@MainActor
final class RecognizerRequestTimeoutTests: XCTestCase {
    func testMissingSelectionOrManagementReplyReleasesOnlyItsPendingRequest() async throws {
        for action in ["select", "unload", "download"] {
            let voice = RecognizerBindingTests.voice()
            voice.processingAckTimeout = .milliseconds(10)
            var sent: [[String: Any]] = []
            voice.sendCommand = { sent.append($0) }
            voice.setConnectionStatus(true)
            voice.handleEvent(RecognizerBindingTests.event(1, assetsPresent: action != "download"))
            sent.removeAll()
            func send() {
                if action == "select" { voice.selectRecognizer(.parakeet) }
                else { voice.manageRecognizer(action == "download" ? .parakeet : .whisper,
                                               action: action == "download" ? .download : .unload) }
            }
            send()
            let original = try XCTUnwrap(sent.last?["id"] as? String)
            XCTAssertEqual(sent.count, 1)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertFalse(voice.recognizerPickerState.isSelectionDisabled, action)
            XCTAssertNotNil(voice.recognizerNotice, action)
            XCTAssertEqual(sent.last?["cmd"] as? String, "get_recognizer_status", action)
            XCTAssertEqual(voice.recognizerPickerState.selected, .whisper, "no optimistic switch")
            send()
            XCTAssertNotEqual(sent.last?["id"] as? String, original, "timeout must release the download latch too")
            XCTAssertEqual(sent.count, 3, "one command, one authoritative refresh, one explicit retry")
            voice.setConnectionStatus(false)
        }
    }

    func testSettledTimeoutCannotClearANewerSelectionOrAddANotice() async throws {
        let voice = RecognizerBindingTests.voice()
        var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(RecognizerBindingTests.event())
        voice.processingAckTimeout = .milliseconds(10)
        voice.selectRecognizer(.parakeet)
        var ack = RecognizerBindingTests.event(2)
        ack["type"] = "ack"; ack["command"] = "set_recognizer"; ack["outcome"] = "reject"
        ack["id"] = sent.last?["id"]; voice.handleEvent(ack)
        voice.processingAckTimeout = .seconds(5)
        voice.selectRecognizer(.parakeet)
        let count = sent.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(voice.recognizerPickerState.isSelectionDisabled)
        XCTAssertNil(voice.recognizerNotice)
        XCTAssertEqual(sent.count, count)
        voice.setConnectionStatus(false)
    }
}
