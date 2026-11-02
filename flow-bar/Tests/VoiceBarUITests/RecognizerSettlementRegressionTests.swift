import XCTest
@testable import VoiceBarUI

@MainActor
final class RecognizerSettlementRegressionTests: XCTestCase {
    func testCorrelatedStaleRejectSettlesIntentWithoutRegressingSnapshot() throws {
        let v = RecognizerBindingTests.voice(); var commands: [[String: Any]] = []
        v.sendCommand = { commands.append($0) }; v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10)); commands.removeAll()
        v.selectRecognizer(.parakeet)
        let selectionID = try XCTUnwrap(commands.last?["id"])
        v.handleEvent(RecognizerBindingTests.event(12))
        var reject = RecognizerBindingTests.event(11, allowed: false, refusal: "voice-busy")
        reject["type"] = "ack"; reject["command"] = "set_recognizer"
        reject["outcome"] = "reject"; reject["reason"] = "voice-busy"; reject["id"] = selectionID
        v.handleEvent(reject)
        XCTAssertEqual(v.recognizerSnapshot?.revision, 12)
        XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled, "Correlated rejection must settle intent while keeping revision 12")
        v.refreshRecognizerStatus()
        var fresh = RecognizerBindingTests.event(13); fresh["id"] = commands.last?["id"]
        v.handleEvent(fresh)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled, "Even explicit authoritative refresh cannot recover this pending intent")
        XCTAssertEqual(commands.map { $0["cmd"] as? String }, ["set_recognizer", "get_recognizer_status"])
    }
    func testStaleAcceptSettlesAndDuplicateOldAckCannotSettleNextIntent() throws {
        let v = RecognizerBindingTests.voice(); var commands: [[String: Any]] = []
        v.sendCommand = { commands.append($0) }; v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10)); commands.removeAll(); v.selectRecognizer(.parakeet)
        let oldID = try XCTUnwrap(commands.last?["id"] as? String)
        v.handleEvent(RecognizerBindingTests.event(12))
        var ack = RecognizerBindingTests.event(11, desired: "parakeet")
        ack["type"] = "ack"; ack["command"] = "set_recognizer"; ack["outcome"] = "accept"; ack["id"] = oldID
        v.handleEvent(ack)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(v.recognizerSnapshot?.revision, 12); XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        v.selectRecognizer(.parakeet)
        XCTAssertEqual(commands.count, 2); XCTAssertNotEqual(commands.last?["id"] as? String, oldID)
        v.handleEvent(ack)
        XCTAssertTrue(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(v.recognizerSnapshot?.revision, 12)
    }
    func testCurrentRejectDoesSettleWithoutQueuedRetry() throws {
        let v = RecognizerBindingTests.voice(); var commands: [[String: Any]] = []
        v.sendCommand = { commands.append($0) }; v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10)); commands.removeAll(); v.selectRecognizer(.parakeet)
        var reject = RecognizerBindingTests.event(10)
        reject["type"] = "ack"; reject["command"] = "set_recognizer"; reject["outcome"] = "reject"
        reject["reason"] = "voice-busy"; reject["id"] = commands.last?["id"]
        v.handleEvent(reject)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        XCTAssertEqual(commands.count, 1)
    }
    func testMalformedSnapshotKeepsActionableReadFailureVisible() {
        let v = RecognizerBindingTests.voice(); v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10))
        v.handleEvent(["type": "recognizer_status", "recognizer_status": ["revision": 11]])
        XCTAssertNil(v.recognizerSnapshot)
        XCTAssertEqual(v.recognizerNotice, "Recognizer status couldn't be read; refresh to try again.")
        XCTAssertTrue(v.recognizerPickerState.explanation?.contains("refresh") == true,
                      "Projection currently drops recognizerNotice on its unavailable early return")
    }
    func testMatchingEqualSnapshotRestoresReadinessAfterMalformedEvent() {
        let v = RecognizerBindingTests.voice(); v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10))
        v.handleEvent(["type": "recognizer_status", "recognizer_status": ["revision": 11]])
        v.handleEvent(RecognizerBindingTests.event(10))
        XCTAssertEqual(v.recognizerSnapshot?.revision, 10)
        XCTAssertNil(v.recognizerNotice)
    }
    func testWrongAckIDAndMalformedOldSnapshotCannotEraseCurrentReady() {
        let v = RecognizerBindingTests.voice(); v.setConnectionStatus(true)
        v.handleEvent(RecognizerBindingTests.event(10))
        v.handleEvent(["type": "ack", "command": "set_recognizer", "outcome": "reject", "id": "foreign", "recognizer_status": [:]])
        v.handleEvent(["type": "recognizer_status", "recognizer_status": ["revision": 9]])
        XCTAssertEqual(v.recognizerSnapshot?.revision, 10)
        XCTAssertEqual(v.recognizerPickerState.whisper, .loaded)
    }
    func testErrorStringsNeverLeakRawMachineCodes() throws {
        let p = RecognizerBindingTests.event(desired: "parakeet", effective: nil, phase: "error", parakeet: "error", whisper: "sleeping", allowed: false, refusal: "cleanup-unconfirmed")["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: p)))
        XCTAssertTrue(state.isSelectionDisabled)
        XCTAssertFalse(state.explanation?.contains("cleanup-unconfirmed") == true)
        XCTAssertTrue(state.explanation?.contains("reconnect") == true)
    }
}
