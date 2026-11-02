import AppKit
import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class SpeakSelectionCaptureTests: XCTestCase {
    func testTimedOutCopyDistinguishesEmptyAndUnreadableAX() {
        for axText: String? in ["", nil] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            seed(board)
            let original = contents(board)
            var time = 0.0
            var copies = 0
            let capture = makeCapture(readAXSelection: { axText }, pasteboard: board, postCopy: {
                copies += 1
                return true // No selection was copied: the clipboard generation stays unchanged.
            }, now: { time += 1; return time })
            let done = expectation(description: axText == nil ? "unreadable AX" : "empty AX")
            capture.capture { result in
                XCTAssertEqual(result.outcome, axText == nil ? .copyTimedOut : .nothingSelected)
                XCTAssertNil(result.text)
                XCTAssertEqual(copies, 1)
                XCTAssertEqual(self.contents(board), original)
                let report = self.reportToState(result)
                XCTAssertEqual(report.message, axText == nil ? "Timed out\nReselect" : "Select text\nfirst")
                XCTAssertEqual(report.commands, 0)
                XCTAssertEqual(report.details["outcome"], axText == nil ? "copy_timeout" : "nothing_selected")
                XCTAssertEqual(report.details["ax_read"], axText == nil ? "unavailable" : "empty")
                XCTAssertEqual(report.details["path"], "copy")
                XCTAssertEqual(report.details["copy_attempted"], "true")
                XCTAssertEqual(report.details["copy_resolution"], "copy_timeout")
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testBrowserCopyRoutingRestoresEveryClipboardRepresentation() {
        for bundle in ["com.t3tools.t3code", "net.imput.helium", "com.google.Chrome", "com.google.Chrome.beta",
                       "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium"] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            seed(board)
            let original = contents(board)
            var ax = clipboardFocus()
            let app = SelectionFocusAX.AppIdentity(pid: 42, startTime: 1)
            ax.frontmostApp = { app }
            ax.bundleIdentifier = { _ in bundle }
            var copies = 0
            let capture = makeCapture(focusAX: ax, readAXSelection: { "AX keeps spaces but loses structure" },
                                      pasteboard: board, postCopy: {
                copies += 1
                board.clearContents()
                board.setString("and the row should say Stopped", forType: .string)
                return true
            })
            let done = expectation(description: bundle)
            capture.capture { result in
                XCTAssertEqual(result.text, "and the row should say Stopped", bundle)
                XCTAssertEqual(result.path, .copy, bundle)
                XCTAssertEqual(self.contents(board), original, bundle)
                XCTAssertEqual(copies, 1, bundle)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testSpacelessAXUsesCopyOnlyWhenItRestoresMatchingWordBoundaries() {
        for (axText, copied, repaired) in [
            ("andtherowshouldsayStopped", "and the row should say Stopped", true),
            ("andtherowshouldsayStopped", "andtherowshouldsayStopped", false),
            ("andtherowshouldsayStopped", "unrelated copied selection", false),
            ("averylongunchangedidentifierinthetext andtherowshouldsayStopped",
             "averylongunchangedidentifierinthetext and the row should say Stopped", true),
        ] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            seed(board)
            let original = contents(board)
            var copies = 0
            var ax = clipboardFocus()
            ax.frontmostApp = { .init(pid: 42, startTime: 1) }
            let capture = makeCapture(focusAX: ax, readAXSelection: { axText }, pasteboard: board, postCopy: {
                copies += 1
                board.clearContents()
                board.setString(copied, forType: .string)
                return true
            })
            let done = expectation(description: copied)
            capture.capture { result in
                XCTAssertEqual(result.text, repaired ? copied : axText)
                XCTAssertEqual(result.path, repaired ? .copy : .ax)
                XCTAssertEqual(copies, 1)
                XCTAssertEqual(self.contents(board), original)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testSpacelessComparisonKeepsAXOnEmptyOrTimedOutCopyOnly() {
        let text = String(repeating: "a1b2", count: 8)
        for bundle in ["com.example.editor", "net.imput.helium", "com.t3tools.t3code"] {
            for outcome in ["timeout", "empty", "nonstring", "copyFailure"] {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                seed(board)
                let original = contents(board)
                var ax = clipboardFocus()
                ax.frontmostApp = { .init(pid: 42, startTime: 1) }
                ax.bundleIdentifier = { _ in bundle }
                var copies = 0
                let capture = makeCapture(focusAX: ax, readAXSelection: { text }, pasteboard: board, postCopy: {
                    copies += 1
                    if outcome == "empty" || outcome == "nonstring" {
                        board.clearContents()
                        if outcome == "empty" { board.setString("", forType: .string) }
                        else { board.setData(Data([0, 255]), forType: .png) }
                    }
                    return outcome != "copyFailure"
                })
                let done = expectation(description: "\(bundle) \(outcome)")
                capture.capture { result in
                    let keepsAX = bundle == "com.example.editor" && outcome != "copyFailure"
                    XCTAssertEqual(result.outcome, keepsAX ? .completed : outcome == "timeout" ? .copyTimedOut
                        : outcome == "copyFailure" ? .copyFailed : .copyEmpty)
                    XCTAssertEqual(result.text, keepsAX ? text : nil)
                    XCTAssertEqual(result.path, keepsAX ? .ax : .copy)
                    XCTAssertEqual(copies, 1)
                    XCTAssertEqual(self.contents(board), original)
                    done.fulfill()
                }
                wait(for: [done], timeout: 2)
            }
        }
    }

    func testSpacelessAXWithoutPinnedAppNeverCopiesOrTouchesClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board), generation = board.changeCount
        let text = String(repeating: "a1b2", count: 8)
        let capture = makeCapture(snapshotReader: { XCTFail("AX must not snapshot"); return nil },
            readAXSelection: { text }, pasteboard: board, postCopy: { XCTFail("Copy must be pinned"); return false })
        let done = expectation(description: "AX without source identity")
        capture.capture { result in
            XCTAssertEqual(result.outcome, .completed)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.path, .ax)
            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(self.contents(board), original)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testSelectionCapturePathTravelsWithSpeechCommand() {
        for path in [SelectionCaptureResult.Path.ax, .copy, .unknown, .clipboard] {
            let state = VoiceState()
            state.isConnected = true
            var command: [String: Any] = [:]
            state.sendCommand = { command = $0 }
            state.selectionTextCaptureHandler = { $0(.completed("selected words").observed(axRead: .text, path: path)) }
            state.speakSelection()
            XCTAssertEqual(command["capture_path"] as? String, path == .ax || path == .copy ? path.rawValue : nil)
        }
    }

    func testBrowserAndSpacelessFallbackFailClosedOnFocusSecurityClipboardAndRestoreChanges() {
        for bundle in ["net.imput.helium", "com.example.editor"] {
            for scenario in ["focus", "secure", "race", "restore"] {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                seed(board)
                let original = contents(board)
                let snapshot = SelectionPasteboardSnapshot.readOnMain(name: board.name.rawValue)
                var app = SelectionFocusAX.AppIdentity(pid: 42, startTime: 1)
                var secure = false, copies = 0
                var ax = clipboardFocus()
                ax.frontmostApp = { app }
                ax.bundleIdentifier = { _ in bundle }
                ax.secureInputEnabled = { secure }
                let capture = SpeakSelectionCapture(focusAX: ax, snapshotReader: {
                    DispatchQueue.main.sync {
                        if scenario == "focus" { app.startTime += 1 }
                        if scenario == "secure" { secure = true }
                    }
                    return snapshot
                }, writeRestoredItems: { scenario == "restore" ? false : board.writeObjects($0) },
                readAXSelection: { "andtherowshouldsayStopped" }, pasteboard: board, postCopy: {
                    copies += 1
                    board.clearContents()
                    board.setString("and the row should say Stopped", forType: .string)
                    if scenario == "race" { board.clearContents(); board.setString("newer user copy", forType: .string) }
                    return true
                })
                let expected: SelectionCaptureResult = scenario == "focus" ? .captureFailed
                    : scenario == "secure" ? .secureField : scenario == "race" ? .clipboardChanged : .clipboardRestoreFailed
                captureAndWait(capture, expectedResult: expected) { XCTAssertNil($0) }
                XCTAssertEqual(copies, scenario == "focus" || scenario == "secure" ? 0 : 1)
                if scenario == "race" { XCTAssertEqual(board.string(forType: .string), "newer user copy") }
                if scenario == "focus" || scenario == "secure" { XCTAssertEqual(contents(board), original) }
            }
        }
    }

    func testExplicitClipboardReadsExactTextWithoutCopySnapshotOrWrites() {
        for text: String? in ["  שלום 👩🏽‍💻 e\u{301}\r\n\tend…\n", " \n\t", "", nil] {
            var reads = 0
            let capture = clipboardCapture(read: { reads += 1; return text })
            XCTAssertEqual(reads, 0, "constructing capture must not read")
            let done = expectation(description: "explicit clipboard")
            capture.readClipboard(isCurrent: { true }) { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(result.outcome, .completed)
                XCTAssertEqual(result.text.map { Array($0.utf8) }, text.map { Array($0.utf8) })
                XCTAssertEqual(result.path, .clipboard)
                XCTAssertEqual(reads, 1)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testExplicitClipboardRefusesSecureUnknownCancelledAndChangedReads() {
        for scenario in ["secure-input", "secure-focus", "unknown-focus", "untrusted", "cancelled",
                         "race", "late-secure", "late-race", "late-cancelled"] {
            var reads = 0, generation = 10
            var secure = scenario == "secure-input"
            var current = scenario != "cancelled"
            var ax = clipboardFocus()
            ax.secureInputEnabled = { secure }
            ax.trusted = { scenario != "untrusted" }
            ax.queryFocus = {
                if scenario == "unknown-focus" { return (.noValue, nil) }
                if scenario == "secure-focus" { return (.success, .init(role: "AXTextField", subrole: "AXSecureTextField")) }
                if scenario == "late-race", reads > 0 { generation += 1 }
                return (.success, .init(role: "AXTextArea", subrole: nil))
            }
            let capture = clipboardCapture(ax: ax, generation: { generation }, read: {
                reads += 1
                if scenario == "race" { generation += 1 }
                if scenario == "late-secure" { secure = true }
                if scenario == "late-cancelled" { current = false }
                return "synthetic text"
            })
            let done = expectation(description: scenario)
            capture.readClipboard(isCurrent: { current }) { result in
                XCTAssertNil(result.text)
                XCTAssertEqual(result.outcome, scenario.contains("race") ? .clipboardChanged
                    : scenario.contains("secure") ? .secureField : .captureFailed)
                XCTAssertEqual(reads, ["race", "late-secure", "late-race", "late-cancelled"].contains(scenario) ? 1 : 0)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testClipboardSubroleDecoderEvidenceGuardsBothWindowsOnly() {
        let cases: [(AXError, CFTypeRef?, Bool)] = [(.cannotComplete, nil, false), (.failure, nil, false),
            (.success, NSNumber(value: 42), false), (.success, nil, true), (.noValue, nil, true),
            (.attributeUnsupported, nil, true), (.success, "AXTextArea" as CFString, true)]
        for (status, value, allowed) in cases {
            for late in [false, true] {
                var reads = 0, sends = 0
                var ax = clipboardFocus()
                ax.queryFocus = {
                    SelectionFocusAX.decodeFocus(AXUIElementCreateApplication(0)) { key in
                        if key == kAXRoleAttribute { return (.success, "AXTextField" as CFString) }
                        return !late || reads > 0 ? (status, value) : (.success, nil)
                    }
                }
                XCTAssertNil(SpeakSelectionCapture.preflight(ax, recover: false, copyExemptApp: nil).blockReason,
                             "Ordinary selection admission stays unchanged")
                let state = VoiceState()
                state.isConnected = true
                state.sendCommand = { _ in sends += 1 }
                let capture = clipboardCapture(ax: ax, read: { reads += 1; return "valid text" })
                let done = expectation(description: "subrole evidence")
                state.clipboardTextReadHandler = { current, complete in
                    capture.readClipboard(isCurrent: current) { result in
                        complete(result)
                        XCTAssertEqual(reads, allowed || late ? 1 : 0)
                        XCTAssertEqual(sends, allowed ? 1 : 0)
                        XCTAssertEqual(result.outcome, allowed ? .completed : .captureFailed)
                        done.fulfill()
                    }
                }
                state.readClipboard()
                wait(for: [done], timeout: 2)
            }
        }
    }

    private func clipboardFocus() -> SelectionFocusAX {
        SelectionFocusAX(secureInputEnabled: { false }, trusted: { true },
            queryFocus: { (.success, .init(role: "AXTextArea", subrole: nil)) }, frontmostApp: { nil },
            isChromiumFamily: { _ in XCTFail("no Chromium exemption"); return false },
            setManualAccessibility: { _ in XCTFail("no AX recovery"); return .failure },
            sleep: { _ in XCTFail("no focus recovery retries") })
    }

    private func clipboardCapture(ax: SelectionFocusAX? = nil, generation: @escaping () -> Int = { 10 },
                                  read: @escaping () -> String?) -> SpeakSelectionCapture {
        SpeakSelectionCapture(focusAX: ax ?? clipboardFocus(),
            snapshotReader: { XCTFail("clipboard read must not snapshot/export"); return nil },
            writeRestoredItems: { _ in XCTFail("clipboard read must not write/restore"); return false },
            readAXSelection: { XCTFail("clipboard read must not capture selection"); return nil },
            postCopy: { XCTFail("clipboard read must not synthesize Copy"); return false },
            readCopiedString: read, clipboardChangeCount: generation)
    }

    func testSecureInputAndSecureSubroleAreBothRecognized() {
        XCTAssertTrue(SpeakSelectionCapture.isSecureFocus(role: "AXTextField", subrole: "AXSecureTextField", secureInput: false))
        XCTAssertTrue(SpeakSelectionCapture.isSecureFocus(role: "AXSecureTextField", subrole: nil, secureInput: false))
        XCTAssertTrue(SpeakSelectionCapture.isSecureFocus(role: "AXTextArea", subrole: nil, secureInput: true))
        XCTAssertFalse(SpeakSelectionCapture.isSecureFocus(role: "AXTextArea", subrole: nil, secureInput: false))
    }

    func testSnapshotHelperDeadlineLeavesClipboardUntouchedAndMainResponsive() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board)
        let count = board.changeCount
        let finished = expectation(description: "owned helper timed out")
        let mainPulse = expectation(description: "main ran while helper was pending")
        let pasteboardName = board.name.rawValue
        DispatchQueue.global(qos: .utility).async {
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = SelectionPasteboardSnapshot.readInHelper(
                name: pasteboardName, executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"], timeout: 0.2)
            XCTAssertNil(snapshot)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
            finished.fulfill()
        }
        DispatchQueue.main.async { mainPulse.fulfill() }
        wait(for: [mainPulse, finished], timeout: 3)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(contents(board), original)
    }

    func testExhaustedRestoreFailureHasDedicatedResult() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let capture = makeCapture(writeRestoredItems: { _ in false }, readAXSelection: { nil }, pasteboard: board,
            postCopy: { board.clearContents(); board.setString("selection", forType: .string); return true })
        captureAndWait(capture, expectedResult: .clipboardRestoreFailed) { XCTAssertNil($0) }
    }

    func testSecureFocusNeverReadsSelectionOrPostsCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board)
        let count = board.changeCount
        let capture = makeCapture(canCapture: { false }, readAXSelection: {
            XCTFail("secure focus must not read selected text")
            return "secret"
        }, pasteboard: board, postCopy: { XCTFail("secure focus must not copy"); return false })
        captureAndWait(capture) { XCTAssertNil($0) }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(contents(board), original)
    }

    func testPartialNativeWriteRetriesUsingFreshPasteboardItems() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board)
        var writes = 0
        let capture = makeCapture(writeRestoredItems: { items in
            writes += 1
            if writes == 1 {
                let count = board.changeCount
                XCTAssertTrue(board.writeObjects([items[0]]))
                XCTAssertEqual(board.changeCount, count, "our data write keeps the cleared generation")
                return false // first item accepted before the reported failure
            }
            return board.writeObjects(items)
        }, readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("selection", forType: .string)
            return true
        })
        captureAndWait(capture) { XCTAssertEqual($0, "selection") }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(contents(board), original)
    }

    func testNewCopyAfterFailedRestoreIsPreservedWithoutRetry() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        var writes = 0
        let capture = makeCapture(writeRestoredItems: { _ in
            writes += 1
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            return false
        }, readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("selection", forType: .string)
            return true
        })
        captureAndWait(capture, expectedResult: .clipboardChanged) { XCTAssertNil($0) }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
    }

    func testPendingSnapshotDoesNotBlockMainAndCopyWaitsForSnapshot() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "finished")
        var copies = 0
        let capture = makeCapture(snapshotReader: {
            XCTAssertFalse(Thread.isMainThread, "snapshot IPC must not run on the tap loop")
            DispatchQueue.main.async { release.signal() }
            XCTAssertEqual(release.wait(timeout: .now() + 0.5), .success)
            return []
        }, readAXSelection: { nil }, pasteboard: board, postCopy: {
            copies += 1
            board.clearContents()
            board.setString("selection", forType: .string)
            return true
        })
        capture.capture { XCTAssertEqual($0.text, "selection"); finished.fulfill() }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(copies, 1)
    }

    func testNewerClipboardDuringCopyReadSurvivesAndAbortsSpeech() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let capture = makeCapture(readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("our selected text", forType: .string)
            return true
        }, readCopiedString: {
            let text = board.string(forType: .string)
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            return text
        })
        let finished = expectation(description: "change-race report")
        capture.capture { result in
            XCTAssertNil(result.text, "a read spanning two owners is not trustworthy")
            let report = self.reportToState(result)
            XCTAssertEqual(report.details["outcome"], "clipboard_changed")
            XCTAssertEqual(report.details["ax_read"], "unavailable")
            XCTAssertEqual(report.details["path"], "copy")
            XCTAssertEqual(report.message, "Clipboard\nReselect")
            XCTAssertEqual(report.commands, 0)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
    }

    func testMultipleOwnershipChangesBeforePollingPreserveLatestCopyAndAbortSpeech() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let capture = makeCapture(readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("our selected text", forType: .string)
            board.clearContents()
            board.setString("foreign app copy", forType: .string)
            return true
        })
        captureAndWait(capture, expectedResult: .clipboardChanged) { XCTAssertNil($0) }
        XCTAssertEqual(board.string(forType: .string), "foreign app copy")
    }

    func testPendingAXReaderDoesNotBlockMainAndCompletionReturnsToMain() {
        let readerEntered = expectation(description: "AX reader entered")
        let finished = expectation(description: "capture completed on main")
        let releaseReader = DispatchSemaphore(value: 0)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = makeCapture(readAXSelection: {
            XCTAssertFalse(Thread.isMainThread, "AX must not run on the event-tap run loop")
            readerEntered.fulfill()
            DispatchQueue.main.async { releaseReader.signal() }
            XCTAssertEqual(releaseReader.wait(timeout: .now() + 1), .success,
                           "main must process its pulse while the AX reader is still pending")
            return "selection"
        }, pasteboard: board)
        capture.capture {
            XCTAssertTrue(Thread.isMainThread, "VoiceState completion must run on main")
            XCTAssertEqual($0.text, "selection")
            finished.fulfill()
        }
        wait(for: [readerEntered, finished], timeout: 2)
    }

    func testAXSelectionLeavesPasteboardUntouchedAndPreservesRawMarkdown() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board)
        let changeCount = board.changeCount
        let capture = makeCapture(readAXSelection: { "  **שלום**\n[link](https://example.com)  " },
                                            pasteboard: board, postCopy: { XCTFail("AX must not copy"); return false })
        captureAndWait(capture) { XCTAssertEqual($0, "  **שלום**\n[link](https://example.com)  ") }
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(contents(board), original)
    }

    func testFallbackRestoresEveryItemAndTypeOnSuccessAndFailure() {
        for outcome in ["text", "empty", "nonstring", "timeout", "copyFailure", "emptyAX"] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            seed(board)
            let original = contents(board)
            var time = 0.0
            var jobs: [(TimeInterval, () -> Void)] = []
            var copies = 0
            var completions = 0
            let ready = expectation(description: "capture completed or polling yielded")
            var signaledReady = false
            let signalReady = {
                if !signaledReady { signaledReady = true; ready.fulfill() }
            }
            let capture = makeCapture(readAXSelection: { outcome == "emptyAX" ? "" : nil },
                pasteboard: board, postCopy: {
                    copies += 1
                    if outcome != "timeout", outcome != "copyFailure" {
                        board.clearContents()
                        if outcome != "nonstring" {
                            board.setString(outcome == "empty" ? "" : "raw **selection**", forType: .string)
                        } else {
                            board.setData(Data([0, 255]), forType: .png)
                        }
                    }
                    return outcome != "copyFailure"
                }, schedule: { jobs.append(($0, $1)); signalReady() }, now: { time })
            capture.capture { selection in
                completions += 1
                signalReady()
                XCTAssertEqual(selection.text, ["text", "emptyAX"].contains(outcome) ? "raw **selection**" : nil)
                XCTAssertEqual(self.contents(board), original, "restore must precede completion: \(outcome)")
                let report = self.reportToState(selection)
                XCTAssertEqual(report.details["ax_read"], outcome == "emptyAX" ? "empty" : "unavailable", outcome)
                XCTAssertEqual(report.details["path"], "copy", outcome)
                let expectedOutcome = ["empty": "copy_empty", "nonstring": "copy_empty",
                                       "timeout": "copy_timeout", "copyFailure": "copy_failed"][outcome] ?? "completed"
                XCTAssertEqual(report.details["outcome"], expectedOutcome, outcome)
                let expectedMessage = ["empty": "No text\nReselect",
                                       "nonstring": "No text\nReselect",
                                       "timeout": "Timed out\nReselect",
                                       "copyFailure": "Can't copy\nCheck A11y"][outcome]
                XCTAssertEqual(report.message, expectedMessage, outcome)
                XCTAssertEqual(report.commands, ["text", "emptyAX"].contains(outcome) ? 1 : 0)
                XCTAssertFalse(report.details.values.contains { $0.contains("raw **selection**") || $0.contains("original text") })
            }
            wait(for: [ready], timeout: 2)
            while !jobs.isEmpty, time < 1 {
                let (delay, job) = jobs.removeFirst()
                time += delay
                job()
            }
            XCTAssertEqual(copies, 1, outcome)
            XCTAssertEqual(completions, 1, outcome)
            XCTAssertEqual(contents(board), original, outcome)
            if outcome == "timeout" { XCTAssertEqual(time, 0.4, accuracy: 0.021) }
        }
    }

    func testDelayedCopyWaitsForChangeCountAndRestoresAnEmptyClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        var time = 0.0
        var jobs: [(TimeInterval, () -> Void)] = []
        var result: String?
        let polling = expectation(description: "polling yielded")
        let capture = makeCapture(readAXSelection: { nil }, pasteboard: board, postCopy: { true },
                                            schedule: { jobs.append(($0, $1)); polling.fulfill() }, now: { time })
        capture.capture { result = $0.text }
        wait(for: [polling], timeout: 2)
        XCTAssertNil(result)
        XCTAssertEqual(jobs.count, 1, "polling must yield rather than block the hotkey/UI run loop")
        board.clearContents()
        board.setString("copied later", forType: .string)
        if let (delay, job) = jobs.first { time += delay; job() }
        XCTAssertEqual(result, "copied later")
        XCTAssertEqual(contents(board), [])
    }

    func testUnreadableAdvertisedRepresentationFailsBeforeCopying() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(Data("text".utf8), forType: .string)
        item.setData(Data([0, 255]), forType: .rtf) // AppKit advertises an unreadable derived UTF16 type.
        board.writeObjects([item])
        let original = contents(board)
        let count = board.changeCount
        let capture = makeCapture(readAXSelection: { nil }, pasteboard: board,
                                            postCopy: { XCTFail("cannot replace an unsaved clipboard"); return false })
        captureAndWait(capture) { XCTAssertNil($0) }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(contents(board), original)
    }

    func testAXAndCopyProvenanceCountsOnlyTheObservedStringAndNeverLogsPayload() {
        for usesAX in [true, false] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            seed(board)
            let original = contents(board)
            let count = board.changeCount
            let text = "PRIVATE_SENTINEL שלום👩🏽‍💻\r\n\r\n- first\n2. second\n| A | B |\na\tb\n\u{FFFC}"
            let capture = makeCapture(readAXSelection: { usesAX ? text : nil }, pasteboard: board, postCopy: {
                if usesAX { XCTFail("AX must not copy"); return false }
                board.clearContents()
                board.setString(text, forType: .string)
                return true
            })
            let finished = expectation(description: "AX trace")
            capture.capture { result in
                XCTAssertEqual(result.text, text)
                let report = self.reportToState(result)
                XCTAssertEqual(report.details["ax_read"], usesAX ? "text" : "unavailable")
                XCTAssertEqual(report.details["path"], usesAX ? "ax" : "copy")
                XCTAssertEqual(report.details["outcome"], "completed")
                XCTAssertEqual(report.details["host_structure"], "not_observed")
                XCTAssertEqual(report.details["utf16_count"], String(text.utf16.count))
                XCTAssertEqual(report.details["line_breaks"], "6")
                XCTAssertEqual(report.details["list_marker_lines"], "2")
                XCTAssertEqual(report.details["pipe_lines"], "1")
                XCTAssertEqual(report.details["tabs"], "1")
                XCTAssertEqual(report.details["object_replacements"], "1")
                XCTAssertFalse(report.details.values.contains { $0.contains("PRIVATE_SENTINEL") || $0.contains("שלום") })
                XCTAssertEqual(report.commands, 1)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
            if usesAX { XCTAssertEqual(board.changeCount, count) }
            XCTAssertEqual(contents(board), original)
        }
    }

    private func reportToState(_ result: SelectionCaptureResult) -> (details: [String: String], message: String?, commands: Int) {
        let state = VoiceState()
        var events: [(String, [String: String])] = []
        var commands = 0
        state.diagnosticLogger = { events.append(($0, $1)) }
        state.sendCommand = { _ in commands += 1 }
        state.selectionTextCaptureHandler = { $0(result) }
        state.speakSelection()
        XCTAssertEqual(events.filter { $0.0 == "selection_capture" }.count, 1)
        return (events.first { $0.0 == "selection_capture" }?.1 ?? [:], state.confirmationText, commands)
    }

    private func makeCapture(focusAX: SelectionFocusAX? = nil, canCapture: @escaping () -> Bool = { true },
                             snapshotReader: (() -> SpeakSelectionCapture.Snapshot?)? = nil,
                             writeRestoredItems: (([NSPasteboardItem]) -> Bool)? = nil,
                             readAXSelection: @escaping () -> String?, pasteboard: NSPasteboard,
                             postCopy: @escaping () -> Bool = { false }, readCopiedString: (() -> String?)? = nil,
                             schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
                             now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> SpeakSelectionCapture {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceBar")
        let pasteboardName = pasteboard.name.rawValue
        return SpeakSelectionCapture(canCapture: canCapture, focusAX: focusAX ?? clipboardFocus(), snapshotReader: snapshotReader ?? {
            SelectionPasteboardSnapshot.readInHelper(name: pasteboardName, executable: executable)
        }, writeRestoredItems: writeRestoredItems, readAXSelection: readAXSelection, pasteboard: pasteboard,
           postCopy: postCopy, readCopiedString: readCopiedString, schedule: schedule ?? {
               DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + $0, execute: $1)
           }, now: now)
    }

    private func captureAndWait(_ capture: SpeakSelectionCapture, expectedResult: SelectionCaptureResult? = nil,
                                assertion: @escaping (String?) -> Void) {
        let finished = expectation(description: "capture finished")
        capture.capture {
            XCTAssertTrue(Thread.isMainThread)
            if let expectedResult { XCTAssertEqual($0.outcome, expectedResult.outcome) }
            assertion($0.text)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    private func seed(_ board: NSPasteboard) {
        board.clearContents()
        let first = NSPasteboardItem()
        first.setData(Data("original text".utf8), forType: .string)
        first.setData(Data("{\\rtf1\\ansi original text}".utf8), forType: .rtf)
        first.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let second = NSPasteboardItem()
        second.setData(Data([4, 0, 254]), forType: NSPasteboard.PasteboardType("dyn.voicebar-selection-test"))
        second.setData(Data([42]), forType: NSPasteboard.PasteboardType("com.example.private-format"))
        XCTAssertTrue(board.writeObjects([first, second]))
    }

    private func contents(_ board: NSPasteboard) -> [[String: Data?]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, item.data(forType: $0)) })
        }
    }
}
