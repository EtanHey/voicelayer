import AppKit
@testable import VoiceBar
import XCTest

final class SpeakSelectionCaptureTests: XCTestCase {
    func testNewerClipboardDuringCopyReadSurvivesAndAbortsSpeech() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let capture = SpeakSelectionCapture(readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("our selected text", forType: .string)
            return true
        }, readCopiedString: {
            let text = board.string(forType: .string)
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            return text
        })
        captureAndWait(capture) { XCTAssertNil($0, "a read spanning two owners is not trustworthy") }
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
    }

    func testMultipleOwnershipChangesBeforePollingPreserveLatestCopyAndAbortSpeech() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let capture = SpeakSelectionCapture(readAXSelection: { nil }, pasteboard: board, postCopy: {
            board.clearContents()
            board.setString("our selected text", forType: .string)
            board.clearContents()
            board.setString("foreign app copy", forType: .string)
            return true
        })
        captureAndWait(capture) { XCTAssertNil($0) }
        XCTAssertEqual(board.string(forType: .string), "foreign app copy")
    }

    func testPendingAXReaderDoesNotBlockMainAndCompletionReturnsToMain() {
        let readerEntered = expectation(description: "AX reader entered")
        let finished = expectation(description: "capture completed on main")
        let releaseReader = DispatchSemaphore(value: 0)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = SpeakSelectionCapture(readAXSelection: {
            XCTAssertFalse(Thread.isMainThread, "AX must not run on the event-tap run loop")
            readerEntered.fulfill()
            DispatchQueue.main.async { releaseReader.signal() }
            XCTAssertEqual(releaseReader.wait(timeout: .now() + 1), .success,
                           "main must process its pulse while the AX reader is still pending")
            return "selection"
        }, pasteboard: board)
        capture.capture {
            XCTAssertTrue(Thread.isMainThread, "VoiceState completion must run on main")
            XCTAssertEqual($0, "selection")
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
        let capture = SpeakSelectionCapture(readAXSelection: { "  **שלום**\n[link](https://example.com)  " },
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
            let capture = SpeakSelectionCapture(readAXSelection: { outcome == "emptyAX" ? "" : nil },
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
                XCTAssertEqual(selection, ["text", "emptyAX"].contains(outcome) ? "raw **selection**" : nil)
                XCTAssertEqual(self.contents(board), original, "restore must precede completion: \(outcome)")
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
        let capture = SpeakSelectionCapture(readAXSelection: { nil }, pasteboard: board, postCopy: { true },
                                            schedule: { jobs.append(($0, $1)); polling.fulfill() }, now: { time })
        capture.capture { result = $0 }
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
        let capture = SpeakSelectionCapture(readAXSelection: { nil }, pasteboard: board,
                                            postCopy: { XCTFail("cannot replace an unsaved clipboard"); return false })
        captureAndWait(capture) { XCTAssertNil($0) }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(contents(board), original)
    }

    private func captureAndWait(_ capture: SpeakSelectionCapture, assertion: @escaping (String?) -> Void) {
        let finished = expectation(description: "capture finished")
        capture.capture {
            XCTAssertTrue(Thread.isMainThread)
            assertion($0)
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
