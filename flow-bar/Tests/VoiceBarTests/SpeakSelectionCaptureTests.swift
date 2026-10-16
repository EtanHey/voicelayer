import AppKit
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class SpeakSelectionCaptureTests: XCTestCase {
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
            XCTAssertEqual(report.message, "Clipboard\nchanged")
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
                                       "timeout": "Copy timed\nout; retry",
                                       "copyFailure": "Check app\naccess"][outcome]
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

    private func makeCapture(canCapture: @escaping () -> Bool = { true },
                             snapshotReader: (() -> SpeakSelectionCapture.Snapshot?)? = nil,
                             writeRestoredItems: (([NSPasteboardItem]) -> Bool)? = nil,
                             readAXSelection: @escaping () -> String?, pasteboard: NSPasteboard,
                             postCopy: @escaping () -> Bool = { false }, readCopiedString: (() -> String?)? = nil,
                             schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
                             now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> SpeakSelectionCapture {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/VoiceBar")
        let pasteboardName = pasteboard.name.rawValue
        return SpeakSelectionCapture(canCapture: canCapture, snapshotReader: snapshotReader ?? {
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
