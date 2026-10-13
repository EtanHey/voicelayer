import AppKit
@testable import VoiceBar
import XCTest

final class SpeakSelectionCaptureTests: XCTestCase {
    func testAXSelectionLeavesPasteboardUntouchedAndPreservesRawMarkdown() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        seed(board)
        let original = contents(board)
        let changeCount = board.changeCount
        let capture = SpeakSelectionCapture(readAXSelection: { "  **שלום**\n[link](https://example.com)  " },
                                            pasteboard: board, postCopy: { XCTFail("AX must not copy"); return false })
        capture.capture { XCTAssertEqual($0, "  **שלום**\n[link](https://example.com)  ") }
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
            let capture = SpeakSelectionCapture(readAXSelection: { outcome == "emptyAX" ? "" : nil },
                pasteboard: board, postCopy: {
                    copies += 1
                    if outcome != "timeout" {
                        board.clearContents()
                        if outcome != "nonstring" {
                            board.setString(outcome == "empty" ? "" : "raw **selection**", forType: .string)
                        } else {
                            board.setData(Data([0, 255]), forType: .png)
                        }
                    }
                    return outcome != "copyFailure"
                }, schedule: { jobs.append(($0, $1)) }, now: { time })
            capture.capture { selection in
                completions += 1
                XCTAssertEqual(selection, ["text", "emptyAX"].contains(outcome) ? "raw **selection**" : nil)
                XCTAssertEqual(self.contents(board), original, "restore must precede completion: \(outcome)")
            }
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
        let capture = SpeakSelectionCapture(readAXSelection: { nil }, pasteboard: board, postCopy: { true },
                                            schedule: { jobs.append(($0, $1)) }, now: { time })
        capture.capture { result = $0 }
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
        capture.capture { XCTAssertNil($0) }
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(contents(board), original)
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
