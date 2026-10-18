import AppKit
import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// A freshly launched Electron/Chromium app keeps its AX tree off, so the focus query answers
/// kAXErrorNoValue until an assistive client sets AXManualAccessibility (T3AX1, 2026-10-18).
final class SelectionFocusRecoveryTests: XCTestCase {
    private final class FakeAX {
        var statuses: [AXError]
        var focus = SelectionFocusAX.Focus(role: "AXTextArea", subrole: nil)
        var secureInput = false
        var trusted = true
        var pid: pid_t? = 4242
        var setResult: AXError = .success
        var queries = 0
        var sets: [pid_t] = []
        var sleeps: [TimeInterval] = []

        init(_ statuses: [AXError]) { self.statuses = statuses }

        var ax: SelectionFocusAX {
            SelectionFocusAX(
                secureInputEnabled: { self.secureInput },
                trusted: { self.trusted },
                queryFocus: {
                    self.queries += 1
                    let status = self.statuses.count > 1 ? self.statuses.removeFirst() : self.statuses[0]
                    return (status, status == .success ? self.focus : nil)
                },
                frontmostPID: { self.pid },
                setManualAccessibility: { self.sets.append($0); return self.setResult },
                sleep: { self.sleeps.append($0) })
        }
    }

    // MARK: preflight

    func testReadableFocusNeverTouchesManualAccessibility() {
        let fake = FakeAX([.success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertNil(result.blockReason)
        XCTAssertNil(result.axEnable)
        XCTAssertEqual(result.retries, 0)
        XCTAssertFalse(result.unreadableFocusAllowsCopy)
        XCTAssertEqual(fake.sets, [])
        XCTAssertEqual(fake.queries, 1)
        XCTAssertEqual(fake.sleeps, [])
    }

    func testNoValueSetsManualAccessibilityOnFrontmostAppAndRetriesUntilFocusIsReadable() {
        let fake = FakeAX([.noValue, .noValue, .noValue, .success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertNil(result.blockReason)
        XCTAssertEqual(result.axEnable, .set)
        XCTAssertEqual(result.retries, 3)
        XCTAssertEqual(fake.sets, [4242])
        XCTAssertFalse(result.unreadableFocusAllowsCopy)
    }

    func testCannotCompleteAlsoRecovers() {
        let fake = FakeAX([.cannotComplete, .success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertNil(result.blockReason)
        XCTAssertEqual(result.axEnable, .set)
        XCTAssertEqual(result.retries, 1)
    }

    func testRetryWaitIsBoundedAndPersistentNoValueAllowsCopyOnlyForAnAppThatAcceptedManualAccessibility() {
        let fake = FakeAX([.noValue])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertNil(result.blockReason, "a Chromium-family app that accepted the flag may use preserved-clipboard Copy")
        XCTAssertTrue(result.unreadableFocusAllowsCopy)
        XCTAssertEqual(result.axEnable, .attempted)
        XCTAssertEqual(result.retries, SpeakSelectionCapture.focusRetryLimit)
        let waited = fake.sleeps.reduce(0, +)
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        XCTAssertLessThanOrEqual(waited, 1.0)
        XCTAssertTrue(fake.sleeps.allSatisfy { $0 <= 0.15 }, "small steps")
    }

    func testAppRefusingManualAccessibilityKeepsTheOldCaptureFailure() {
        let fake = FakeAX([.noValue])
        fake.setResult = .attributeUnsupported
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertEqual(result.axEnable, .failed)
        XCTAssertEqual(result.retries, 0)
        XCTAssertFalse(result.unreadableFocusAllowsCopy)
        XCTAssertEqual(fake.sleeps, [])
    }

    func testOtherFocusErrorsAndMissingFrontmostAppDoNotAttemptRecovery() {
        for status in [AXError.failure, .apiDisabled, .notImplemented] {
            let fake = FakeAX([status])
            let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
            XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
            XCTAssertNil(result.axEnable)
            XCTAssertEqual(fake.sets, [])
        }
        let fake = FakeAX([.noValue])
        fake.pid = nil
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertNil(result.axEnable)
    }

    func testSecureInputAndTrustStillWinBeforeAnyAXCall() {
        let secure = FakeAX([.noValue])
        secure.secureInput = true
        XCTAssertEqual(SpeakSelectionCapture.preflight(secure.ax, recover: true, allowUnreadableFocus: false)
            .blockReason?.outcome, .secureField)
        XCTAssertEqual(secure.queries, 0)
        XCTAssertEqual(secure.sets, [])
        let untrusted = FakeAX([.noValue])
        untrusted.trusted = false
        XCTAssertEqual(SpeakSelectionCapture.preflight(untrusted.ax, recover: true, allowUnreadableFocus: false)
            .blockReason?.outcome, .captureFailed)
        XCTAssertEqual(untrusted.queries, 0)
    }

    func testRecoveredSecureFocusIsStillASecureField() {
        let fake = FakeAX([.noValue, .success])
        fake.focus = SelectionFocusAX.Focus(role: "AXTextField", subrole: "AXSecureTextField")
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, allowUnreadableFocus: false)
        XCTAssertEqual(result.blockReason?.outcome, .secureField)
        XCTAssertEqual(result.axEnable, .set)
    }

    func testRecheckWithoutRecoveryHonoursTheEarlierCopyAllowanceButNotSecureInput() {
        let fake = FakeAX([.noValue])
        let recheck = SpeakSelectionCapture.preflight(fake.ax, recover: false, allowUnreadableFocus: true)
        XCTAssertNil(recheck.blockReason)
        XCTAssertEqual(fake.sets, [], "the recheck must not set the flag again")
        XCTAssertEqual(fake.sleeps, [])
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, allowUnreadableFocus: false)
            .blockReason?.outcome, .captureFailed)
        fake.secureInput = true
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, allowUnreadableFocus: true)
            .blockReason?.outcome, .secureField)
    }

    // MARK: end to end through capture and VoiceState

    func testNoValueManualAXRetrySucceedsAndReadsTextWithoutTouchingTheClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let count = board.changeCount
        let fake = FakeAX([.noValue, .success])
        let capture = makeCapture(fake, readAXSelection: { "selected in t3" }, pasteboard: board,
                                  postCopy: { XCTFail("AX recovered; must not copy"); return false })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "completed")
        XCTAssertEqual(report.details["path"], "ax")
        XCTAssertEqual(report.details["ax_read"], "text")
        XCTAssertEqual(report.details["preflight_ax_enable"], "set")
        XCTAssertEqual(report.details["preflight_retries"], "1")
        XCTAssertEqual(report.spoken, ["selected in t3"])
        XCTAssertEqual(board.changeCount, count)
    }

    func testPersistentNoValueFallsBackToPreservedClipboardCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let fake = FakeAX([.noValue])
        let capture = makeCapture(fake, readAXSelection: { XCTFail("focus is unreadable"); return nil },
                                  pasteboard: board, postCopy: {
                                      board.clearContents()
                                      board.setString("copied from t3", forType: .string)
                                      return true
                                  })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "completed")
        XCTAssertEqual(report.details["path"], "copy")
        XCTAssertEqual(report.details["ax_read"], "not_attempted")
        XCTAssertEqual(report.details["preflight_ax_enable"], "attempted")
        XCTAssertEqual(report.details["preflight_retries"], String(SpeakSelectionCapture.focusRetryLimit))
        XCTAssertEqual(report.spoken, ["copied from t3"])
        XCTAssertEqual(board.string(forType: .string), "original", "clipboard restored")
        XCTAssertEqual(fake.sets.count, 1, "the copy recheck must not set the flag or wait again")
    }

    func testBothFailingShowsVisibleErrorNeverSilent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let fake = FakeAX([.noValue])
        let capture = makeCapture(fake, readAXSelection: { nil }, pasteboard: board, postCopy: { false })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "copy_failed")
        XCTAssertEqual(report.details["preflight_ax_enable"], "attempted")
        XCTAssertEqual(report.message, "Can't copy\nCheck A11y")
        XCTAssertEqual(report.spoken, [])
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testNonElectronAppRefusingTheFlagShowsTheExistingReadError() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.noValue])
        fake.setResult = .attributeUnsupported
        let capture = makeCapture(fake, readAXSelection: { XCTFail("blocked"); return nil }, pasteboard: board,
                                  postCopy: { XCTFail("no copy without a readable focus"); return false })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "capture_failed")
        XCTAssertEqual(report.details["preflight_ax_enable"], "failed")
        XCTAssertEqual(report.message, "Couldn't read the selection, try again")
        XCTAssertEqual(report.spoken, [])
    }

    func testReadableAppDiagnosticsCarryNoPreflightFields() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.success])
        let report = run(makeCapture(fake, readAXSelection: { "native" }, pasteboard: board))
        XCTAssertNil(report.details["preflight_ax_enable"])
        XCTAssertNil(report.details["preflight_retries"])
        XCTAssertEqual(report.spoken, ["native"])
        XCTAssertEqual(fake.sets, [])
    }

    // MARK: helpers

    private func makeCapture(_ fake: FakeAX, readAXSelection: @escaping () -> String?, pasteboard: NSPasteboard,
                             postCopy: @escaping () -> Bool = { false }) -> SpeakSelectionCapture {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/VoiceBar")
        let pasteboardName = pasteboard.name.rawValue
        let ax = fake.ax
        return SpeakSelectionCapture(focusAX: ax, snapshotReader: {
            SelectionPasteboardSnapshot.readInHelper(name: pasteboardName, executable: executable)
        }, readAXSelection: readAXSelection, pasteboard: pasteboard, postCopy: postCopy, schedule: {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + $0, execute: $1)
        })
    }

    private func run(_ capture: SpeakSelectionCapture) -> (details: [String: String], message: String?, spoken: [String]) {
        let state = VoiceState()
        var events: [(String, [String: String])] = []
        var spoken: [String] = []
        state.diagnosticLogger = { events.append(($0, $1)) }
        state.sendCommand = { if let text = $0["text"] as? String { spoken.append(text) } }
        let finished = expectation(description: "capture finished")
        state.selectionTextCaptureHandler = { completion in
            capture.capture { completion($0); finished.fulfill() }
        }
        state.speakSelection()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(events.filter { $0.0 == "selection_capture" }.count, 1)
        return (events.first { $0.0 == "selection_capture" }?.1 ?? [:], state.confirmationText, spoken)
    }
}
