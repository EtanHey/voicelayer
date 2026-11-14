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
        var front: NSRunningApplication? = App("com.t3tools.t3code", 10001)
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
                "delivery_id": id, "recording_path": "synthetic-" + id, "text": text])
        }
    }
    func testListOwnedPartialUsesLegacyUnverifiedReceiptAndRetainsOriginal() throws {
        let kit = Kit(), id = try kit.start()
        var done: ((ListDeliveryMachine.Outcome) -> Void)?
        kit.state.listTypingHandler = { text, pid, completion in
            XCTAssertEqual(text, "1. Alpha\n2. Beta"); XCTAssertEqual(pid, 10001)
            done = completion
        }
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
        kit.state.targetAppActivator = { _ in }
        var received = 0
        kit.state.listTypingHandler = { text, pid, done in
            received += 1; XCTAssertEqual(text, "1. Alpha\n2. Beta"); XCTAssertEqual(pid, 10001)
            done(.refused)
        }
        kit.state.repasteTranscript("1. Alpha\n2. Beta")
        XCTAssertEqual(received, 1); XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
    }
    func testNativeListKeepsAXRouteAndNeverCallsMachine() throws {
        let k = Kit(); k.front = App("test.native", 10001)
        k.state.listTypingHandler = { _, _, _ in XCTFail("Native app retains AX") }
        let id = try k.start(); k.final(id, text: "1. Alpha\n2. Beta")
        XCTAssertEqual(k.writes, ["start:1. Alpha\n2. Beta"])
    }
    func testSecureAndIneligibleListNeverEntersMachine() throws {
        for secure in [true, false] {
            let k = Kit(); k.secure = secure; k.editable = false
            k.state.focusedTargetEligibilityProvider = {
                DictationFocusedTargetEligibility(processIdentifier: 10001, role: "AXButton", isEditable: false, isSecure: secure, matchesCurrentFocus: { true })
            }
            k.state.listTypingHandler = { _, _, _ in XCTFail("Existing guards must run first") }
            let id = try k.start(); k.final(id, text: "1. Alpha\n2. Beta")
            XCTAssertEqual(k.typed, []); XCTAssertEqual(k.writes, [])
        }
    }
    func testListRepasteActivatesThenDelivers() {
        let k = Kit(); var activated = false
        k.state.captureSettingsHistoryPasteTarget()
        k.front = App("test.other", 10002)
        k.state.targetAppActivator = { app in activated = true; k.front = app }
        k.state.listTypingHandler = { _, _, done in XCTAssertTrue(activated); done(.posted) }
        k.state.repasteTranscript("1. Alpha\n2. Beta", source: "settings_history")
        XCTAssertTrue(activated)
    }
    @MainActor func testListIsQuitBusyWhileWorkerOutstanding() {
        let k = Kit()
        k.state.listDeliveryActive = { true }; k.state.mode = .idle
        XCTAssertTrue(k.state.isQuitBusy); XCTAssertFalse(k.state.isUpdateDrainIdle)
    }
    func testDeclinedCaptureUsesGuardedLegacyRoute() throws {
        let k = Kit()
        k.state.listTypingHandler = { _, _, done in done(.declined) }
        let id = try k.start(); k.final(id, text: "1. Alpha\n2. Beta")
        XCTAssertEqual(k.typed, ["start:1. Alpha\n2. Beta"])
    }
    func testPartialNoteUsesOwnRecordingPathWithDuplicateText() throws {
        let k = Kit(); let text = "1. Alpha\n2. Beta"
        k.state.targetAppActivator = { _ in }
        var done: ((ListDeliveryMachine.Outcome) -> Void)?
        k.state.listTypingHandler = { _, _, callback in done = callback }
        let first = try k.start(); k.final(first, text: text)
        let firstDone = try XCTUnwrap(done)
        k.state.handleEvent(["type": "transcription", "job_kind": "history", "recording_path": "synthetic-other", "text": text])
        firstDone(.partial(delivered: "1. Alpha\n", remaining: "2. Beta"))
        XCTAssertTrue(k.state.recentTranscriptionEntries.first { $0.recordingPath == "synthetic-" + first }?.deliveryNote?.contains("including the part already typed") == true)
        XCTAssertFalse(k.state.recentTranscriptionEntries.first { $0.recordingPath == "synthetic-other" }?.deliveryNote?.contains("Partially typed") == true)
    }
    func testCmuxListPillShowsTranscript() throws {
        let k = Kit(); k.front = App("com.cmuxterm.app", 10001)
        k.state.listTypingHandler = { _, _, done in done(.posted) }
        let id = try k.start(); k.final(id, text: "1. Alpha\n2. Beta")
        XCTAssertEqual(k.state.confirmationText, "1. Alpha\n2. Beta")
    }
    func testListCannotOvertakeInFlightAXInsertion() throws {
        let k = Kit(); k.front = App("test.native", 10001)
        var pending: ((DictationInsertionResult) -> Void)?
        k.state.asyncDictationInsertionHandlerProvider = { { text, done in pending = done; return true } }
        let first = try k.start(); k.final(first, text: "Alpha")
        k.state.chromiumFamilyAppDetector = { _ in true }
        k.state.listTypingHandler = { _, _, _ in XCTFail("Earlier AX write is in flight") }
        k.state.targetAppActivator = { _ in }
        k.state.repasteTranscript("1. Alpha\n2. Beta")
        XCTAssertNotNil(pending)
    }
}
