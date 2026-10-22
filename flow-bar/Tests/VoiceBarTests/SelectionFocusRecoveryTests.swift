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
        static let appA = SelectionFocusAX.AppIdentity(pid: 4242, startTime: 1_000_001)
        static let appB = SelectionFocusAX.AppIdentity(pid: 5353, startTime: 2_000_002)
        var front: SelectionFocusAX.AppIdentity? = FakeAX.appA
        /// Apps whose bundle is Chromium/Electron. Only these can earn the unreadable-focus Copy exemption.
        var chromium: Set<pid_t> = [FakeAX.appA.pid]
        /// When set, classify through the production detector against these bundles instead.
        var bundles: [pid_t: URL]?
        var frontQueries = 0
        /// Runs before each frontmost query (1-based), so a test can switch apps at an exact point.
        var onFrontmostQuery: (Int) -> Void = { _ in }
        /// Runs on each retry sleep, so a test can switch apps mid-wait.
        var onSleep: (Int) -> Void = { _ in }
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
                frontmostApp: {
                    self.frontQueries += 1
                    self.onFrontmostQuery(self.frontQueries)
                    return self.front
                },
                isChromiumFamily: { app in
                    guard let bundles = self.bundles else { return self.chromium.contains(app.pid) }
                    return ChromiumFamilyApps.contains(bundleURL: bundles[app.pid])
                },
                setManualAccessibility: { self.sets.append($0.pid); return self.setResult },
                sleep: { self.sleeps.append($0); self.onSleep(self.sleeps.count) })
        }
    }

    // MARK: preflight

    func testReadableFocusNeverTouchesManualAccessibility() {
        let fake = FakeAX([.success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertNil(result.blockReason)
        XCTAssertNil(result.axEnable)
        XCTAssertEqual(result.retries, 0)
        XCTAssertNil(result.copyExemptApp)
        XCTAssertEqual(fake.sets, [])
        XCTAssertEqual(fake.queries, 1)
        XCTAssertEqual(fake.sleeps, [])
    }

    func testNoValueSetsManualAccessibilityOnFrontmostAppAndRetriesUntilFocusIsReadable() {
        let fake = FakeAX([.noValue, .noValue, .noValue, .success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertNil(result.blockReason)
        XCTAssertEqual(result.axEnable, .set)
        XCTAssertEqual(result.retries, 3)
        XCTAssertEqual(fake.sets, [4242])
        XCTAssertNil(result.copyExemptApp)
    }

    func testCannotCompleteAlsoRecovers() {
        let fake = FakeAX([.cannotComplete, .success])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertNil(result.blockReason)
        XCTAssertEqual(result.axEnable, .set)
        XCTAssertEqual(result.retries, 1)
    }

    func testRetryWaitIsBoundedAndPersistentNoValueAllowsCopyOnlyForAnAppThatAcceptedManualAccessibility() {
        let fake = FakeAX([.noValue])
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertNil(result.blockReason, "a Chromium-family app that accepted the flag may use preserved-clipboard Copy")
        XCTAssertEqual(result.copyExemptApp, FakeAX.appA)
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
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertEqual(result.axEnable, .failed)
        XCTAssertEqual(result.retries, 0)
        XCTAssertNil(result.copyExemptApp)
        XCTAssertEqual(fake.sleeps, [])
    }

    func testOtherFocusErrorsAndMissingFrontmostAppDoNotAttemptRecovery() {
        for status in [AXError.failure, .apiDisabled, .notImplemented] {
            let fake = FakeAX([status])
            let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
            XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
            XCTAssertNil(result.axEnable)
            XCTAssertEqual(fake.sets, [])
        }
        let fake = FakeAX([.noValue])
        fake.front = nil
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertNil(result.axEnable)
    }

    func testSecureInputAndTrustStillWinBeforeAnyAXCall() {
        let secure = FakeAX([.noValue])
        secure.secureInput = true
        XCTAssertEqual(SpeakSelectionCapture.preflight(secure.ax, recover: true, copyExemptApp: nil)
            .blockReason?.outcome, .secureField)
        XCTAssertEqual(secure.queries, 0)
        XCTAssertEqual(secure.sets, [])
        let untrusted = FakeAX([.noValue])
        untrusted.trusted = false
        XCTAssertEqual(SpeakSelectionCapture.preflight(untrusted.ax, recover: true, copyExemptApp: nil)
            .blockReason?.outcome, .captureFailed)
        XCTAssertEqual(untrusted.queries, 0)
    }

    func testAppSwitchDuringRetriesGrantsNoCopyExemption() {
        let fake = FakeAX([.noValue])
        fake.onSleep = { if $0 == 3 { fake.front = FakeAX.appB } }
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertNil(result.copyExemptApp)
        XCTAssertEqual(result.axEnable, .attempted)
    }

    func testRecheckRefusesADifferentAppOrARelaunchedProcessWithTheSamePID() {
        let fake = FakeAX([.noValue])
        fake.front = FakeAX.appB
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
            .blockReason?.outcome, .captureFailed)
        fake.front = SelectionFocusAX.AppIdentity(pid: FakeAX.appA.pid, startTime: 9_999_999)
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
            .blockReason?.outcome, .captureFailed)
        fake.front = nil
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
            .blockReason?.outcome, .captureFailed)
        XCTAssertEqual(fake.sets, [])
    }

    func testExemptionRecheckRefusesAnotherAppEvenWhenItsFocusIsReadable() {
        let fake = FakeAX([.success])
        fake.front = FakeAX.appB
        let recheck = SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
        XCTAssertEqual(recheck.blockReason?.outcome, .captureFailed)
        XCTAssertNil(recheck.copyExemptApp)
    }

    func testSetterSuccessAloneNeverGrantsTheCopyExemptionOutsideChromium() {
        let fake = FakeAX([.noValue])
        fake.chromium = []
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
        XCTAssertEqual(result.axEnable, .attempted)
        XCTAssertNil(result.copyExemptApp)
    }

    // PASTE2 R1 (Sol P2): the Copy exemption rests on Chromium's secure-input behaviour, so a
    // native bundle with only an app.asar resource (or an app.asar directory) must not earn it.
    func testUncorroboratedAsarBundleNeverGrantsTheCopyExemption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pa2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let resourceOnly = root.appendingPathComponent("ResourceOnly.app/Contents/Resources")
        try fileManager.createDirectory(at: resourceOnly, withIntermediateDirectories: true)
        try Data("asar".utf8).write(to: resourceOnly.appendingPathComponent("app.asar"))
        let asarDirectory = root.appendingPathComponent("AsarDirectory.app")
        try fileManager.createDirectory(at: asarDirectory.appendingPathComponent("Contents/Resources/app.asar"),
                                        withIntermediateDirectories: true)
        let electronData = asarDirectory.appendingPathComponent("Contents/Frameworks/X Framework.framework/Resources")
        try fileManager.createDirectory(at: electronData, withIntermediateDirectories: true)
        for name in ["icudtl.dat", "resources.pak"] {
            try Data("x".utf8).write(to: electronData.appendingPathComponent(name))
        }
        for bundle in [root.appendingPathComponent("ResourceOnly.app"), asarDirectory] {
            let fake = FakeAX([.noValue])
            fake.bundles = [FakeAX.appA.pid: bundle]
            let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
            XCTAssertEqual(result.blockReason?.outcome, .captureFailed, bundle.lastPathComponent)
            XCTAssertNil(result.copyExemptApp, bundle.lastPathComponent)
        }

        // Control: the same path grants it to a real Electron bundle.
        let electron = root.appendingPathComponent("Claude.app/Contents/Frameworks/Electron Framework.framework")
        try fileManager.createDirectory(at: electron, withIntermediateDirectories: true)
        let fake = FakeAX([.noValue])
        fake.bundles = [FakeAX.appA.pid: root.appendingPathComponent("Claude.app")]
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil).copyExemptApp,
                       FakeAX.appA)
    }

    func testRecoveredSecureFocusIsStillASecureField() {
        let fake = FakeAX([.noValue, .success])
        fake.focus = SelectionFocusAX.Focus(role: "AXTextField", subrole: "AXSecureTextField")
        let result = SpeakSelectionCapture.preflight(fake.ax, recover: true, copyExemptApp: nil)
        XCTAssertEqual(result.blockReason?.outcome, .secureField)
        XCTAssertEqual(result.axEnable, .set)
    }

    func testRecheckWithoutRecoveryHonoursTheEarlierCopyAllowanceButNotSecureInput() {
        let fake = FakeAX([.noValue])
        let recheck = SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
        XCTAssertNil(recheck.blockReason)
        XCTAssertEqual(fake.sets, [], "the recheck must not set the flag again")
        XCTAssertEqual(fake.sleeps, [])
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: nil)
            .blockReason?.outcome, .captureFailed)
        fake.secureInput = true
        XCTAssertEqual(SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: FakeAX.appA)
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
        XCTAssertEqual(report.details["copy_attempted"], "true")
        XCTAssertEqual(report.details["copy_resolution"], "copy_failed")
        XCTAssertEqual(report.details["preflight_ax_enable"], "attempted")
        XCTAssertEqual(report.message, "Can't copy\nCheck A11y")
        XCTAssertEqual(report.spoken, [])
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    /// Sol's trace: A earns the exemption, the user switches to B while the clipboard is snapshotted,
    /// and B's unreadable focus must never receive a synthesized Cmd+C.
    func testSwitchToAnotherAppDuringClipboardSnapshotNeverCopiesIntoIt() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let count = board.changeCount
        let fake = FakeAX([.noValue])
        fake.chromium = [FakeAX.appA.pid] // B is not Chromium and would refuse the flag
        let capture = makeCapture(fake, readAXSelection: { XCTFail("no selection read"); return nil },
                                  pasteboard: board, postCopy: {
            XCTFail("Cmd+C must not reach app B"); return false
        }, beforeSnapshot: { fake.front = FakeAX.appB })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "capture_failed")
        XCTAssertEqual(report.details["preflight_ax_enable"], "attempted")
        XCTAssertEqual(report.details["preflight_recheck_reason"], "app_changed")
        XCTAssertEqual(report.details["copy_attempted"], "false")
        XCTAssertEqual(report.message, "Couldn't read the selection, try again")
        XCTAssertEqual(report.spoken, [])
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(fake.sets, [FakeAX.appA.pid], "the recheck never sets the flag")
        XCTAssertEqual(fake.sleeps.count, SpeakSelectionCapture.focusRetryLimit, "the recheck never waits again")
        XCTAssertFalse(fake.secureInput)
    }

    /// The last identity check runs on main immediately before the synthesized Cmd+C.
    func testSwitchAfterTheRecheckButBeforeCopyNeverCopiesIntoTheNewApp() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let fake = FakeAX([.noValue])
        // Frontmost queries: 1 recovery target, 2 after retries, 3 Copy recheck, 4 immediately before Copy.
        fake.onFrontmostQuery = { if $0 == 4 { fake.front = FakeAX.appB } }
        let capture = makeCapture(fake, readAXSelection: { XCTFail("no selection read"); return nil },
                                  pasteboard: board, postCopy: { XCTFail("Cmd+C must not reach app B"); return false })
        let report = run(capture)
        XCTAssertEqual(report.details["copy_attempted"], "false")
        XCTAssertEqual(report.details["copy_resolution"], "not_attempted")
        XCTAssertEqual(fake.frontQueries, 4)
        XCTAssertEqual(report.details["outcome"], "capture_failed")
        XCTAssertEqual(report.message, "Couldn't read the selection, try again")
        XCTAssertEqual(report.spoken, [])
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(fake.sets, [FakeAX.appA.pid])
    }

    func testNonChromiumAppAcceptingTheFlagShowsReadErrorWithoutCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.noValue])
        fake.chromium = []
        let capture = makeCapture(fake, readAXSelection: { XCTFail("no selection read"); return nil },
                                  pasteboard: board, postCopy: { XCTFail("setter success is not a Copy grant"); return false })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "capture_failed")
        XCTAssertEqual(report.details["preflight_ax_enable"], "attempted")
        XCTAssertEqual(report.message, "Couldn't read the selection, try again")
        XCTAssertEqual(report.spoken, [])
    }

    func testSwitchToAnotherAppDuringRetriesShowsReadErrorWithoutCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.noValue])
        fake.onSleep = { if $0 == 2 { fake.front = FakeAX.appB } }
        let capture = makeCapture(fake, readAXSelection: { XCTFail("blocked"); return nil }, pasteboard: board,
                                  postCopy: { XCTFail("Cmd+C must not reach app B"); return false })
        let report = run(capture)
        XCTAssertEqual(report.details["outcome"], "capture_failed")
        XCTAssertEqual(report.message, "Couldn't read the selection, try again")
        XCTAssertEqual(report.spoken, [])
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

    func testReadableAppDiagnosticsDoNotClaimRecovery() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.success])
        let report = run(makeCapture(fake, readAXSelection: { "native" }, pasteboard: board))
        XCTAssertNil(report.details["preflight_ax_enable"])
        XCTAssertNil(report.details["preflight_retries"])
        XCTAssertEqual(report.spoken, ["native"])
        XCTAssertEqual(fake.sets, [])
    }

    func testDiagnosticReasonsDoNotChangePreflightDecisions() {
        let fake = FakeAX([.success])
        func reason() -> String? {
            let result = SpeakSelectionCapture.preflight(fake.ax, recover: false, copyExemptApp: nil)
            return result.blockReason?.diagnosticDetails["preflight_recheck_reason"]
        }
        fake.secureInput = true
        XCTAssertEqual(reason(), "secure_input")
        fake.secureInput = false
        fake.trusted = false
        XCTAssertEqual(reason(), "ax_untrusted")
        fake.trusted = true
        fake.focus = .init(role: nil, subrole: nil)
        XCTAssertEqual(reason(), "role_absent")
        fake.focus = .init(role: "AXTextField", subrole: "AXSecureTextField")
        XCTAssertEqual(reason(), "secure_role")
        fake.statuses = [.apiDisabled]
        XCTAssertEqual(reason(), "focus_query_failed")
    }

    func testFocusFailureReportsBeforeRecoverySetterRetriesAndFinalStatus() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.noValue, .cannotComplete, .success])
        let details = run(makeCapture(fake, readAXSelection: { "private selected words" }, pasteboard: board)).details
        XCTAssertEqual(details["preflight_initial_reason"], "allowed")
        XCTAssertEqual(details["preflight_initial_ax_status"], "-25212")
        XCTAssertEqual(details["preflight_initial_final_ax_status"], "0")
        XCTAssertEqual(details["preflight_initial_manual_ax_attempted"], "true")
        XCTAssertEqual(details["preflight_initial_manual_ax_status"], "0")
        XCTAssertEqual(details["preflight_initial_retry_statuses"], "-25204,0")
        XCTAssertEqual(details["copy_attempted"], "false")
        XCTAssertEqual(details["copy_resolution"], "not_attempted")
        XCTAssertFalse(details.values.contains { $0.contains("private selected words") })
    }

    func testRefusedRecoveryRetainsItsActualErrorAndNoRetries() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fake = FakeAX([.noValue])
        fake.setResult = .attributeUnsupported
        let details = run(makeCapture(fake, readAXSelection: { nil }, pasteboard: board)).details
        XCTAssertEqual(details["preflight_initial_reason"], "focus_query_failed")
        XCTAssertEqual(details["preflight_initial_ax_status"], "-25212")
        XCTAssertEqual(details["preflight_initial_final_ax_status"], "-25212")
        XCTAssertEqual(details["preflight_initial_manual_ax_attempted"], "true")
        XCTAssertEqual(details["preflight_initial_manual_ax_status"], "-25205")
        XCTAssertEqual(details["preflight_initial_retry_statuses"], "")
        XCTAssertEqual(details["copy_attempted"], "false")
    }

    func testCopyDiagnosticsKeepInitialAndRecheckEvidenceAndResolution() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("private clipboard", forType: .string)
        let fake = FakeAX([.noValue])
        let details = run(makeCapture(fake, readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("private selection", forType: .string)
            return true
        })).details
        XCTAssertEqual(details["preflight_initial_reason"], "focus_query_failed")
        XCTAssertEqual(details["preflight_initial_retry_statuses"], Array(repeating: "-25212", count: 8).joined(separator: ","))
        XCTAssertEqual(details["preflight_recheck_reason"], "focus_query_failed")
        XCTAssertEqual(details["preflight_recheck_manual_ax_attempted"], "false")
        XCTAssertEqual(details["copy_attempted"], "true")
        XCTAssertEqual(details["copy_resolution"], "completed")
        XCTAssertEqual(board.string(forType: .string), "private clipboard")
        XCTAssertFalse(details.values.contains { $0.contains("private") })
    }

    func testLiveAdapterClassifiesMalformedFocusAndRoleWithoutLoggingValues() {
        let handle = AXUIElementCreateApplication(0) // inert handle, no IPC
        let cases: [(CFTypeRef?, AXError, CFTypeRef?, String)] = [
            (nil, .success, nil, "focus_absent"),
            ("PRIVATE" as CFString, .success, nil, "focus_wrong_type"),
            (handle, .attributeUnsupported, "PRIVATE" as CFString, "role_query_failed"),
            (handle, .success, nil, "role_absent"),
            (handle, .success, NSNumber(value: 42), "role_wrong_type"),
        ]
        for (value, roleStatus, roleValue, reason) in cases {
            for recover in [true, false] {
                let fake = FakeAX([.success])
                var ax = fake.ax
                ax.queryFocus = {
                    SelectionFocusAX.decodeFocus(value) { key in
                        key == kAXRoleAttribute ? (roleStatus, roleValue) : (.success, nil)
                    }
                }
                let result = SpeakSelectionCapture.preflight(ax, recover: recover, copyExemptApp: nil)
                let prefix = recover ? "preflight_initial_" : "preflight_recheck_"
                let details = result.blockReason?.diagnosticDetails ?? [:]
                XCTAssertEqual(result.blockReason?.outcome, .captureFailed)
                XCTAssertEqual(details[prefix + "reason"], reason)
                XCTAssertEqual(details[prefix + "ax_status"], "0")
                if reason.hasPrefix("role_") {
                    XCTAssertEqual(details[prefix + "role_ax_status"], String(roleStatus.rawValue))
                }
                XCTAssertFalse(details.values.contains { $0.contains("PRIVATE") })
                XCTAssertEqual(fake.sets, [])
            }
        }
    }

    func testCopyResolutionIncludesEmptyTimeoutOwnershipRestoreAndSnapshotFailures() {
        for outcome in ["copy_empty", "copy_timeout", "clipboard_changed", "clipboard_restore_failed", "capture_failed"] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("PRIVATE clipboard", forType: .string)
            let fake = FakeAX([.success])
            var time = 0.0
            let capture = SpeakSelectionCapture(focusAX: fake.ax, snapshotReader: {
                outcome == "capture_failed" ? nil : [[(.string, Data("PRIVATE clipboard".utf8))]]
            }, writeRestoredItems: { board.writeObjects($0) && outcome != "clipboard_restore_failed" },
            readAXSelection: { nil }, pasteboard: board, postCopy: {
                XCTAssertNotEqual(outcome, "capture_failed", "snapshot failure must stop before Copy")
                if outcome != "copy_timeout" {
                    board.clearContents()
                    board.setString(outcome == "copy_empty" ? "" : "PRIVATE selection", forType: .string)
                    if outcome == "clipboard_changed" { board.clearContents() }
                }
                return true
            }, schedule: { delay, work in time += delay; work() }, now: { time })
            let details = run(capture).details
            XCTAssertEqual(details["outcome"], outcome)
            XCTAssertEqual(details["copy_attempted"], String(outcome != "capture_failed"))
            XCTAssertEqual(details["copy_resolution"], outcome == "capture_failed" ? "not_attempted" : outcome)
            XCTAssertFalse(details.values.contains { $0.contains("PRIVATE") })
        }
    }

    func testRoleFailureStillYieldsToSecureSubroleAndSecureInput() {
        for secureInput in [false, true] {
            let fake = FakeAX([.success])
            var ax = fake.ax
            var checks = 0
            ax.secureInputEnabled = { checks += 1; return secureInput && checks == 2 }
            ax.queryFocus = {
                SelectionFocusAX.decodeFocus(AXUIElementCreateApplication(0)) { key in
                    key == kAXRoleAttribute ? (.attributeUnsupported, nil)
                        : (.success, "AXSecureTextField" as CFString)
                }
            }
            let result = SpeakSelectionCapture.preflight(ax, recover: true, copyExemptApp: nil)
            XCTAssertEqual(result.blockReason?.outcome, .secureField)
            XCTAssertEqual(result.details["preflight_initial_reason"], secureInput ? "secure_input" : "secure_role")
            XCTAssertEqual(result.details["preflight_initial_role_ax_status"], "-25205")
        }
    }

    // MARK: helpers

    private func makeCapture(_ fake: FakeAX, readAXSelection: @escaping () -> String?, pasteboard: NSPasteboard,
                             postCopy: @escaping () -> Bool = { false },
                             beforeSnapshot: @escaping () -> Void = {}) -> SpeakSelectionCapture {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceBar")
        let pasteboardName = pasteboard.name.rawValue
        let ax = fake.ax
        return SpeakSelectionCapture(focusAX: ax, snapshotReader: {
            beforeSnapshot()
            return SelectionPasteboardSnapshot.readInHelper(name: pasteboardName, executable: executable)
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
