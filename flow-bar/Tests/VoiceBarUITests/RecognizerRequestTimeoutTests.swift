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

    // Review R2: terminal replies can follow a long cold start or model download.
    func testSlowSelectionRejectReasonSurvivesTheDeadline() async throws {
        let voice = RecognizerBindingTests.voice()
        var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(RecognizerBindingTests.event())
        voice.processingAckTimeout = .milliseconds(10)
        voice.selectRecognizer(.parakeet)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        try await Task.sleep(for: .milliseconds(60)) // daemon still stopping/loading (budget up to 300 s)
        var ack = RecognizerBindingTests.event(2)
        ack["type"] = "ack"; ack["command"] = "set_recognizer"; ack["outcome"] = "reject"
        ack["reason"] = "cleanup-unconfirmed"; ack["id"] = id
        voice.handleEvent(ack)
        XCTAssertEqual(voice.recognizerNotice, RecognizerPickerState.message(for: "cleanup-unconfirmed"),
                       "the daemon's terminal reject reason must reach the user")
        voice.setConnectionStatus(false)
    }

    func testDownloadInProgressPerSnapshotIsNotReportedUnconfirmed() async throws {
        let voice = RecognizerBindingTests.voice()
        var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(RecognizerBindingTests.event(1, assetsPresent: false))
        voice.processingAckTimeout = .milliseconds(10)
        voice.manageRecognizer(.parakeet, action: .download)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        var progress = RecognizerBindingTests.event(2, assetsPresent: false)
        var status = progress["recognizer_status"] as! [String: Any]
        var engines = status["engines"] as! [String: Any]
        var p = engines["parakeet"] as! [String: Any]
        p["download"] = ["state": "downloading", "received_bytes": 1, "total_bytes": 100, "error": NSNull()] as [String: Any]
        engines["parakeet"] = p; status["engines"] = engines; progress["recognizer_status"] = status
        voice.handleEvent(progress) // daemon broadcast: download is live
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(voice.recognizerNotice, "a download the daemon reports as running is not an unconfirmed request")
        var ack = RecognizerBindingTests.event(3, assetsPresent: false)
        ack["type"] = "ack"; ack["command"] = "download_recognizer"; ack["outcome"] = "reject"
        ack["id"] = id; ack["reason"] = "download-cleanup-failed"; voice.handleEvent(ack)
        XCTAssertEqual(voice.recognizerNotice, RecognizerPickerState.message(for: "download-cleanup-failed"))
        voice.setConnectionStatus(false)
    }

    func testActiveLoadOrSwitchRearmsUntilTheSnapshotShowsNoWork() async throws {
        for kind in ["selection", "load", "transition"] {
            let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []
            voice.sendCommand = { sent.append($0) }; voice.processingAckTimeout = .milliseconds(10)
            voice.setConnectionStatus(true)
            voice.handleEvent(RecognizerBindingTests.event(1, whisper: kind == "load" ? "sleeping" : "ready"))
            if kind == "load" { voice.manageRecognizer(.whisper, action: .load) }
            else { voice.selectRecognizer(.parakeet) }
            voice.handleEvent(RecognizerBindingTests.event(2, phase: "loading",
                parakeet: kind == "selection" ? "loading" : "sleeping",
                whisper: kind == "load" ? "loading" : "ready", allowed: false,
                refusal: kind == "transition" ? "transition-active" : nil))
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertNil(voice.recognizerNotice, kind)
            voice.handleEvent(RecognizerBindingTests.event(3))
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertNotNil(voice.recognizerNotice, "\(kind): re-armed deadline must still detect a lost reply")
            XCTAssertEqual(sent.last?["cmd"] as? String, "get_recognizer_status")
            voice.setConnectionStatus(false)
        }
    }

    func testDesiredLoadingBroadcastKeepsTheTerminalReplyCorrelation() async throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []
        voice.sendCommand = { sent.append($0) }; voice.processingAckTimeout = .milliseconds(10)
        voice.setConnectionStatus(true); voice.handleEvent(RecognizerBindingTests.event())
        voice.selectRecognizer(.parakeet); let id = try XCTUnwrap(sent.last?["id"] as? String)
        voice.handleEvent(RecognizerBindingTests.event(2, desired: "parakeet", phase: "loading", parakeet: "loading"))
        try await Task.sleep(for: .milliseconds(60))
        var ack = RecognizerBindingTests.event(3, desired: "parakeet", phase: "error", parakeet: "error")
        ack["type"] = "ack"; ack["command"] = "set_recognizer"; ack["outcome"] = "reject"
        ack["id"] = id; ack["reason"] = "cleanup-unconfirmed"; voice.handleEvent(ack)
        XCTAssertEqual(voice.recognizerNotice, RecognizerPickerState.message(for: "cleanup-unconfirmed"))
        voice.setConnectionStatus(false)
    }

    func testLateLoadAndDownloadRepliesAreConsumedOnceAndCannotSettleTheNextRequest() async throws {
        for action in [RecognizerManagementAction.load, .download] {
            let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []
            voice.sendCommand = { sent.append($0) }; voice.processingAckTimeout = .milliseconds(10)
            voice.setConnectionStatus(true)
            let status = RecognizerBindingTests.event(2, whisper: "sleeping", assetsPresent: action != .download)
            voice.handleEvent(status)
            let engine: RecognizerPickerEngine = action == .load ? .whisper : .parakeet
            voice.manageRecognizer(engine, action: action)
            let oldID = try XCTUnwrap(sent.last?["id"] as? String)
            try await Task.sleep(for: .milliseconds(60))
            var ack = status
            ack["type"] = "ack"; ack["command"] = action.command; ack["outcome"] = "reject"
            ack["id"] = oldID; ack["reason"] = "cleanup-unconfirmed"; voice.handleEvent(ack)
            XCTAssertEqual(voice.recognizerNotice, RecognizerPickerState.message(for: "cleanup-unconfirmed"))
            voice.processingAckTimeout = .seconds(5)
            voice.manageRecognizer(engine, action: action)
            let newID = try XCTUnwrap(sent.last?["id"] as? String)
            XCTAssertNotEqual(newID, oldID)
            voice.handleEvent(ack)
            XCTAssertNil(voice.recognizerNotice, "an old reply cannot overwrite the next request")
            let count = sent.count; voice.manageRecognizer(engine, action: action)
            XCTAssertEqual(sent.count, count, "the old reply must not release the new pending latch")
            voice.setConnectionStatus(false); ack["id"] = newID; voice.handleEvent(ack)
            XCTAssertNil(voice.recognizerSnapshot); XCTAssertNil(voice.recognizerNotice)
        }
    }
}
