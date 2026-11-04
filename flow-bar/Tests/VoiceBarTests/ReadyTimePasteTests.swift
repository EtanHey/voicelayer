import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class ReadyTimePasteTests: XCTestCase {
    private final class App: NSRunningApplication, @unchecked Sendable {
        let name: String
        let pid: pid_t
        init(_ name: String, _ pid: pid_t) { self.name = name; self.pid = pid; super.init() }
        override var bundleIdentifier: String? { name }
        override var processIdentifier: pid_t { pid }
    }
    private final class Kit {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        var front: NSRunningApplication? = App("test.start", 10001)
        var field = "start", secure = false, editable = true
        var writes: [String] = [], typed: [String] = [], commands: [[String: Any]] = []
        var afterWrite: (() -> Void)?
        init() {
            state.isConnected = true
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
        func final(_ id: String) {
            state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live",
                "delivery_id": id, "text": "whole fu… שלום"])
        }
    }
    func testMovedDuringTranscriptionDeliversToReadyFocusExactlyOnce() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("test.ready", 10002); kit.field = "ready"
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, ["ready:whole fu… שלום"])
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .insertedAtCursor)
    }
    func testSameTargetKeepsNativeStrategy() throws {
        let kit = Kit(), id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
    }
    func testSecureReadyFieldIsKeptWithoutAnyWrite() throws {
        let kit = Kit(), id = try kit.start()
        kit.secure = true; kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
    }
    func testNoReadyTargetKeepsHistoryAndExplains() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = nil; kit.final(id)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; copied/kept")
    }
    func testNoneditableReadyTargetIsKept() throws {
        let kit = Kit(), id = try kit.start()
        kit.editable = false; kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
    }
    func testVoiceBarOwnDictionaryFieldIsValid() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App(Bundle.main.bundleIdentifier ?? "test.voicebar", ProcessInfo.processInfo.processIdentifier)
        kit.field = "Dictionary search"; kit.final(id)
        XCTAssertEqual(kit.writes, ["Dictionary search:whole fu… שלום"])
    }
    func testRichHostUsesReadyTargetTypingExactlyOnce() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("com.t3tools.t3code", 10003); kit.field = "T3 scratch"
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.typed, ["T3 scratch:whole fu… שלום"])
    }
    func testFocusMoveAfterWriteNeverRetargetsOrRetries() throws {
        let kit = Kit(), id = try kit.start()
        kit.afterWrite = { kit.field = "elsewhere"; kit.front = App("test.other", 10004) }
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
        XCTAssertEqual(kit.typed, [])
    }
}
