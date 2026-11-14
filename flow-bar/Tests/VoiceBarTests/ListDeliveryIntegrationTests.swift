import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class ListDeliveryIntegrationTests: XCTestCase {
    private final class App: NSRunningApplication, @unchecked Sendable {
        let name: String?
        let pid: pid_t
        init(_ name: String?, _ pid: pid_t) { self.name = name; self.pid = pid; super.init() }
        override var bundleIdentifier: String? { name }
        override var processIdentifier: pid_t { pid }
    }
    private final class Kit {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        var front: NSRunningApplication? = App("test.start", 10001)
        var field = "start", secure = false, editable = true, secureInput = false
        var writes: [String] = [], typed: [String] = [], commands: [[String: Any]] = []
        var afterWrite: (() -> Void)?
        init() {
            state.isConnected = true
            state.secureInputEnabledProvider = { [unowned self] in secureInput }
            state.frontmostAppProvider = { [unowned self] in front }
            state.sendCommand = { [unowned self] in commands.append($0) }
            state.targetAppActivator = { _ in XCTFail("Automatic delivery must not steal focus") }
            state.pasteScheduler = { _, work in work() }
            state.pasteboardWriter = { _ in XCTFail("Keep the user's clipboard") }
            state.dictationTargetIdentityProvider = { [unowned self] in
                let captured = field
                return { [unowned self] in field == captured }
            }
            state.focusedTargetEligibilityProvider = { [unowned self] in
                guard let front else { return nil }
                let captured = field
                return DictationFocusedTargetEligibility(processIdentifier: front.processIdentifier,
                    role: "AXTextField", isEditable: editable, isSecure: secure,
                    matchesCurrentFocus: { [unowned self] in field == captured })
            }
            state.asyncDictationInsertionHandlerProvider = { [unowned self] in
                let captured = field
                return { [unowned self] text, done in
                    writes.append(captured + ":" + text)
                    afterWrite?()
                    done(.verified)
                    return true
                }
            }
            state.ownedTextTypingHandler = { [unowned self] text, _, matches in
                guard matches() else { return .focusChanged }
                typed.append(field + ":" + text); afterWrite?(); return .posted
            }
        }
        func start() throws -> String {
            state.record(pressToTalk: true)
            let id = try XCTUnwrap(commands.last?["take_id"] as? String)
            state.handleEvent(["type": "state", "state": "transcribing", "recording_jobs": [
                ["take_id": id, "kind": "live", "phase": "processing"]]])
            return id
        }
        func final(_ id: String, text: String = "whole fu… שלום") {
            state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live",
                "delivery_id": id, "text": text])
        }
    }
    func testListOwnedPartialUsesLegacyUnverifiedReceiptAndRetainsOriginal() throws {
        let kit = Kit(), id = try kit.start()
        var done: ((ListDeliveryMachine.Outcome) -> Void)?
        kit.state.listTypingHandler = { text, pid, completion in
            XCTAssertEqual(text, "1. Alpha\n2. Beta"); XCTAssertEqual(pid, 10001)
            done = completion
        }
        kit.state.focusedTargetEligibilityProvider = { XCTFail("List must not call AX on main"); return nil }
        kit.final(id, text: "1. Alpha\n2. Beta")
        XCTAssertEqual(kit.commands.filter { $0["cmd"] as? String == "dictation_delivered" }.count, 0)
        try XCTUnwrap(done)(.partial(delivered: "1. Alpha\n", remaining: "2. Beta"))
        let receipts = kit.commands.filter { $0["cmd"] as? String == "dictation_delivered" }
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?["outcome"] as? String, "unverified")
        XCTAssertEqual(kit.state.latestReusableTranscript, "1. Alpha\n2. Beta")
        XCTAssertTrue(kit.state.recentTranscriptionEntries.first?.deliveryNote?.contains("9 of 16") == true)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
    }
    func testManualListEntersMachineBeforeLegacyAXOrTyping() {
        let kit = Kit()
        var received = 0
        kit.state.listTypingHandler = { text, pid, done in
            received += 1; XCTAssertEqual(text, "1. Alpha\n2. Beta"); XCTAssertEqual(pid, 10001)
            done(.refused)
        }
        kit.state.dictationTargetIdentityProvider = { XCTFail("No AX on list main path"); return nil }
        kit.state.asyncDictationInsertionHandlerProvider = { XCTFail("No AX on list main path"); return nil }
        kit.state.repasteTranscript("1. Alpha\n2. Beta")
        XCTAssertEqual(received, 1); XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
    }
}
