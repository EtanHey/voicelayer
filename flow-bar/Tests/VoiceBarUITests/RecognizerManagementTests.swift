import XCTest
@testable import VoiceBarUI

@MainActor
final class RecognizerManagementTests: XCTestCase {
    private func event(_ revision: Int = 1, present: Bool = false, download: String? = nil) -> [String: Any] {
        var event = RecognizerBindingTests.event(revision, parakeetAvailable: nil, assetsPresent: present)
        var payload = event["recognizer_status"] as! [String: Any]
        var engines = payload["engines"] as! [String: Any]
        var p = engines["parakeet"] as! [String: Any]; p["disk_bytes"] = present ? 2_509_000_000 : 0
        if let download {
            p["download"] = ["state": download, "received_bytes": 1024, "total_bytes": 2048, "error": NSNull()]
            payload["switch_allowed"] = false; payload["switch_refusal_reason"] = "transition-active"
        }
        engines["parakeet"] = p; payload["engines"] = engines; event["recognizer_status"] = payload
        return event
    }
    func testNotDownloadedOffersDownloadAndCannotSelectOrLoad() throws {
        let s = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: event()["recognizer_status"] as! [String: Any])))
        XCTAssertFalse(s.assetsPresent(for: .parakeet)); XCTAssertTrue(s.canManage(.parakeet, action: .download))
        XCTAssertFalse(s.canSelect(.parakeet)); XCTAssertFalse(s.canManage(.parakeet, action: .load))
        XCTAssertFalse(s.canManage(.parakeet, action: .delete))
    }
    func testProvisionedNeverLoadedCanSelectAndShowsDeleteInsteadOfDownload() throws {
        let s = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: event(present: true)["recognizer_status"] as! [String: Any])))
        XCTAssertTrue(s.canSelect(.parakeet)); XCTAssertTrue(s.assetsPresent(for: .parakeet))
        XCTAssertTrue(s.canManage(.parakeet, action: .delete)); XCTAssertFalse(s.canManage(.parakeet, action: .download))
        XCTAssertEqual(s.diskBytes[.parakeet], 2_509_000_000)
    }
    func testDownloadSendsOnceAndCancelKeepsOriginalTerminalCorrelation() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(event()); sent.removeAll()
        voice.manageRecognizer(.parakeet, action: .download); voice.manageRecognizer(.parakeet, action: .download)
        XCTAssertEqual(sent.count, 1); let id = try XCTUnwrap(sent.first?["id"] as? String)
        XCTAssertEqual(sent.first?["cmd"] as? String, "download_recognizer")
        voice.handleEvent(event(2, download: "downloading"))
        XCTAssertTrue(voice.recognizerPickerState.canManage(.parakeet, action: .cancelDownload))
        XCTAssertFalse(voice.recognizerPickerState.canManage(.whisper, action: .unload))
        voice.manageRecognizer(.parakeet, action: .cancelDownload)
        XCTAssertEqual(sent.last?["cmd"] as? String, "cancel_recognizer_download")
        voice.handleEvent(["type": "ack", "command": "cancel_recognizer_download", "id": sent.last!["id"]!, "outcome": "accept"])
        XCTAssertTrue(voice.recognizerPickerState.isSelectionDisabled)
        var terminal = event(3); terminal["type"] = "ack"; terminal["command"] = "download_recognizer"
        terminal["id"] = id; terminal["outcome"] = "reject"; terminal["reason"] = "download-cancelled"
        voice.handleEvent(terminal)
        XCTAssertFalse(voice.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(voice.recognizerNotice, "Download cancelled.")
    }
    func testBusyAndLoadedStatesRefuseDestructiveActions() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(event(present: true)); sent.removeAll()
        voice.manageRecognizer(.whisper, action: .delete); XCTAssertTrue(sent.isEmpty)
        voice.mode = .recording; voice.manageRecognizer(.parakeet, action: .download)
        voice.manageRecognizer(.parakeet, action: .delete)
        XCTAssertFalse(sent.contains { $0["cmd"] as? String == "delete_recognizer" || $0["cmd"] as? String == "download_recognizer" })
    }
    func testEqualRevisionReadRefreshesAssetsWithoutChangingRuntimeEvidence() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true); voice.handleEvent(event()); voice.refreshRecognizerStatus()
        var current = event(present: true); current["id"] = sent.last?["id"]; voice.handleEvent(current)
        XCTAssertTrue(voice.recognizerPickerState.canSelect(.parakeet))
        XCTAssertEqual(voice.recognizerPickerState.parakeet, .unloaded)
        XCTAssertNil(voice.recognizerSnapshot?.parakeet.available)
    }
}
