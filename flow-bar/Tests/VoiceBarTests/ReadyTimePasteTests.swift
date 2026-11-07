import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class ReadyTimePasteTests: XCTestCase {
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
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }
    func testNoneditableReadyTargetIsKept() throws {
        let kit = Kit(), id = try kit.start()
        kit.editable = false; kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
    }
    func testVoiceBarOwnDictionaryFieldIsValid() throws {
        let kit = Kit()
        kit.front = NSRunningApplication.current
        kit.field = "Dictionary search"
        let id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.writes, ["Dictionary search:whole fu… שלום"])
    }
    func testRichHostUsesReadyTargetTypingExactlyOnce() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("com.t3tools.t3code", 10003); kit.field = "T3 scratch"
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.typed, ["T3 scratch:whole fu… שלום"])
    }
    /// cmux's Ghostty surface is a focused AXTextArea whose value is not writable.
    /// Terminal delivery must type into it exactly once, without AX or the clipboard.
    func testTerminalReadOnlyTextAreaFocusIsTypedExactlyOnce() throws {
        let kit = Kit(), id = try kit.start()
        let cmux = App("com.cmuxterm.app", 10005)
        kit.front = cmux; kit.field = "cmux"
        kit.state.focusedTargetEligibilityProvider = {
            DictationFocusedTargetEligibility(processIdentifier: cmux.processIdentifier, role: "AXTextArea",
                isEditable: false, isSecure: false, matchesCurrentFocus: { kit.field == "cmux" })
        }
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.typed, ["cmux:whole fu… שלום"])
    }
    func testFocusMoveAfterWriteNeverRetargetsOrRetries() throws {
        let kit = Kit(), id = try kit.start()
        kit.afterWrite = { kit.field = "elsewhere"; kit.front = App("test.other", 10004) }
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
        XCTAssertEqual(kit.typed, [])
    }
    func testSecureEventInputBlocksRichHostBeforeTyping() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("com.t3tools.t3code", 10003); kit.secureInput = true
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
    }
    func testLocalFieldEditorInsertsAtSelectionWithoutAXOrClipboard() {
        let editor = NSTextView()
        editor.string = "before after"; editor.setSelectedRange(NSRange(location: 7, length: 0))
        var results: [DictationInsertionResult] = []
        XCTAssertTrue(LocalDictationTarget.insertion(for: editor)("whole fu… ", { results.append($0) }))
        XCTAssertEqual(editor.string, "before whole fu… after")
        XCTAssertEqual(results, [.verified])
    }
    private final class SecureField: NSSecureTextField, NSTextViewDelegate {}
    func testLocalSecureEditorIsNeverWritten() {
        let editor = NSTextView(), field = SecureField()
        editor.delegate = field
        XCTAssertTrue(LocalDictationTarget.eligibility(for: editor).isSecure)
        XCTAssertFalse(LocalDictationTarget.insertion(for: editor)("secret", { _ in XCTFail("No write") }))
        XCTAssertEqual(editor.string, "")
    }

    func testAppWithoutFocusedInputKeepsWordsWithoutWriting() throws {
        let kit = Kit(), id = try kit.start()
        kit.state.focusedTargetEligibilityProvider = { nil }
        kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }
    func testSecureInputEnabledAtPostingBoundaryRefuses() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("com.t3tools.t3code", 10003)
        kit.state.ownedTextTypingHandler = { _, _, matches in
            kit.secureInput = true
            XCTAssertFalse(matches())
            return .focusChanged
        }
        kit.final(id)
        XCTAssertEqual(kit.writes, []); XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
    }
    func testReentrantFinalDuringWriteCannotDispatchAgain() throws {
        let kit = Kit(), id = try kit.start()
        kit.afterWrite = { kit.final(id) }
        kit.final(id)
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
    }

    func testShiftF5TypesLastTranscriptIntoCurrentInput() {
        let kit = Kit()
        kit.state.handleEvent(["type": "transcription", "text": "last whole words"])
        kit.front = App("com.t3tools.t3code", 10003); kit.field = "current T3 scratch"
        var activated: [pid_t] = []
        kit.state.targetAppActivator = { activated.append($0.processIdentifier) }
        kit.state.textTypingHandler = { text in kit.typed.append(kit.field + ":" + text); return true }
        kit.state.repasteLastTranscript(source: "shift_f5")
        XCTAssertEqual(activated, [10003])
        XCTAssertEqual(kit.typed, ["current T3 scratch:last whole words"])
        XCTAssertEqual(kit.writes, [])
    }

    func testMovedNativeTargetKeepsReadyFocusForTypingFallback() throws {
        let kit = Kit(), id = try kit.start()
        kit.front = App("com.apple.TextEdit", 10005); kit.field = "ready native"
        kit.state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
        kit.final(id); kit.final(id)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.typed, ["ready native:whole fu… שלום"])
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .typed)
    }

    func testFreshAppInstanceNeverReplaysAnEarlierInstanceWrite() throws {
        let original = Kit(), id = try original.start()
        original.final(id)
        XCTAssertEqual(original.writes.count, 1)
        let recovered = Kit()
        recovered.final(id); recovered.final(id)
        XCTAssertEqual(recovered.writes, []); XCTAssertEqual(recovered.typed, [])
        XCTAssertEqual(recovered.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(recovered.state.confirmationText, "Unverified\nIn History")
    }

    func testSameInstanceBridgeReconnectUsesNewReadyFocus() throws {
        let kit = Kit(), id = try kit.start()
        kit.state.setConnectionStatus(false)
        kit.state.setConnectionStatus(true)
        kit.state.handleEvent(["type": "state", "state": "transcribing", "recording_jobs": [
            ["take_id": id, "kind": "live", "phase": "processing"]]])
        kit.front = App("test.reconnected", 10006); kit.field = "after reconnect"
        kit.final(id)
        XCTAssertEqual(kit.writes, ["after reconnect:whole fu… שלום"])
    }

    func testHistoryCallbackCannotReenterAndDispatchTheSameFinalTwice() throws {
        let kit = Kit(), id = try kit.start()
        var replayed = false
        kit.state.onHistoryArchiveChange = { _ in
            guard !replayed else { return }
            replayed = true
            kit.final(id)
        }
        kit.state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live",
            "delivery_id": id, "text": "whole fu… שלום", "recording_path": "/synthetic/audio.wav"])
        XCTAssertTrue(replayed)
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
    }

    func testShiftF5TypesIntoOwnFocusedFieldInsteadOfPreviousApp() throws {
        let kit = Kit(), id = try kit.start()
        kit.final(id)
        kit.front = App(Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processIdentifier)
        kit.field = "Dictionary search"
        kit.state.repasteLastTranscript(source: "shift_f5")
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום", "Dictionary search:whole fu… שלום"])
        XCTAssertEqual(kit.typed, [])
    }
    func testShiftF5WithoutOwnFocusedInputDoesNotUsePreviousApp() throws {
        let kit = Kit(), id = try kit.start()
        kit.final(id)
        kit.front = App(Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processIdentifier)
        kit.state.focusedTargetEligibilityProvider = { nil }
        kit.state.repasteLastTranscript(source: "shift_f5")
        XCTAssertEqual(kit.writes, ["start:whole fu… שלום"])
        XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }

    func testOwnProcessWithoutEditorRefusesWithoutQueryingExternalAX() throws {
        let kit = Kit(), id = try kit.start()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        kit.front = App(Bundle.main.bundleIdentifier, ownPID)
        var externalAXCalls = 0
        kit.state.focusedTargetEligibilityProvider = {
            LocalDictationTarget.captureEligibility(frontmostPID: ownPID, editor: nil) {
                externalAXCalls += 1
                return DictationFocusedTargetEligibility(processIdentifier: ownPID,
                    role: "AXTextField", isEditable: true, isSecure: false, matchesCurrentFocus: { true })
            }
        }
        kit.final(id)
        XCTAssertEqual(externalAXCalls, 0)
        XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }

}
