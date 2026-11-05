import AppKit
import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class SpeakSelectionCaptureDiagnosticsTests: XCTestCase {
    // Real public T3 fixture: M1 capture 2026-11-04T08:51:56Z,
    // T3 0.1.7-nightly.20261104.4151, one Cmd+C, changeCount 882 -> 883.
    private static let axText = "Fixture block for the T3 copy test. This paragraph is plain prose with a comma, an apostrophe that's curly-quoted in rendering, and a full stop.• First bullet with an inline code span voicelayer --version inside it.• Second bullet that wraps onto a second line when the window is narrow enough to force a soft wrap in the renderer.The last paragraph ends the block. It says only that the test is over."
    private static let copiedText = "Fixture block for the T3 copy test. This paragraph is plain prose with a comma, an apostrophe that's curly-quoted in rendering, and a full stop.\n\n- First bullet with an inline code span `voicelayer --version` inside it.\n- Second bullet that wraps onto a second line when the window is narrow enough to force a soft wrap in the renderer.\n\nThe last paragraph ends the block. It says only that the test is over."
    private static let foreignText = "FOREIGN_CLIPBOARD_SENTINEL"

    private enum Scenario: CaseIterable {
        case success, empty, timeout, copyFailed, restoreFailed
        case preCopySnapshot, preCopyFocus, focusOnly, pollDelta, postRead, restore
    }

    private struct Observation {
        var result: SelectionCaptureResult
        var event: [String: String]
        var start: Int
        var copies: Int
        var restores: Int
        var generationDelta: Int
        var bytes: [[Data]]
        var originalBytes: [[Data]]
        var foreignBytes: [[Data]]
        var commands: Int
    }

    func testPreCopySnapshotChangeIsLoggedWithoutCopyOrRestore() {
        assertFields(run(.preCopySnapshot), branch: "pre_copy", offsets: ["pre_copy": 1])
    }

    func testPreCopyFocusGuardChangeIsLoggedWithoutCopyOrRestore() {
        assertFields(run(.preCopyFocus), branch: "pre_copy", offsets: ["pre_copy": 1])
    }

    func testPollDeltaKeepsItsBranchWhenRestoreAlsoSeesTheChangedGeneration() {
        assertFields(run(.pollDelta), branch: "poll_delta", offsets: ["after_copy": 2, "poll": 2, "restore": 2])
    }

    func testPostReadChangeKeepsItsBranchWhenRestoreAlsoSeesTheChangedGeneration() {
        assertFields(run(.postRead), branch: "post_read",
                     offsets: ["after_copy": 1, "poll": 1, "read": 1, "post_read": 2, "restore": 2])
    }

    func testRestoreChangeReportsTheActualOutsideWritersGeneration() {
        assertFields(run(.restore), branch: "restore",
                     offsets: ["after_copy": 1, "poll": 1, "read": 1, "post_read": 1, "restore": 3])
    }

    func testRealSingleChangeCopyLogsCountsWithoutRequiringAXEquality() {
        XCTAssertEqual(Self.axText.utf8.count, 405)
        XCTAssertEqual(Self.copiedText.utf8.count, 408)
        XCTAssertNotEqual(Self.axText, Self.copiedText)
        let observed = run(.success)
        assertFields(observed, branch: nil,
                     offsets: ["after_copy": 1, "poll": 1, "read": 1, "post_read": 1, "restore": 1])
        XCTAssertEqual(observed.result.text.map { Array($0.utf8) }, Array(Self.copiedText.utf8))
    }

    // Run this exact test against bc7487d5 and the diagnostic change. Only the
    // event's added fields differ; outcomes, raw text, writes and bytes must not.
    func testOutcomesAndRestorationBytesMatchBase() {
        for scenario in Scenario.allCases {
            let observed = run(scenario)
            let changed = [.preCopySnapshot, .preCopyFocus, .pollDelta, .postRead, .restore].contains(scenario)
            let outcome: SelectionCaptureResult.Outcome = changed ? .clipboardChanged
                : scenario == .empty ? .copyEmpty : scenario == .timeout ? .copyTimedOut
                : scenario == .copyFailed ? .copyFailed : scenario == .restoreFailed ? .clipboardRestoreFailed
                : scenario == .focusOnly ? .captureFailed : .completed
            XCTAssertEqual(Array(observed.result.outcome.rawValue.utf8), Array(outcome.rawValue.utf8), "\(scenario)")
            XCTAssertEqual(observed.result.text.map { Array($0.utf8) },
                           scenario == .success ? Array(Self.copiedText.utf8) : nil, "\(scenario)")
            XCTAssertEqual(observed.bytes, changed ? observed.foreignBytes
                : scenario == .restoreFailed ? [] : observed.originalBytes, "\(scenario)")
            let attempted = ![.preCopySnapshot, .preCopyFocus, .focusOnly].contains(scenario)
            XCTAssertEqual(observed.copies, attempted ? 1 : 0, "\(scenario)")
            XCTAssertEqual(observed.event["copy_attempted"], String(attempted), "\(scenario)")
            XCTAssertEqual(observed.event["copy_resolution"], attempted ? outcome.rawValue : "not_attempted", "\(scenario)")
            XCTAssertEqual(observed.restores, scenario == .restoreFailed ? 2
                : [.success, .empty, .timeout, .copyFailed, .restore].contains(scenario) ? 1 : 0, "\(scenario)")
            let expectedDelta = scenario == .focusOnly ? 0
                : [.preCopySnapshot, .preCopyFocus, .timeout, .copyFailed].contains(scenario) ? 1
                : [.restore, .restoreFailed].contains(scenario) ? 3 : 2
            XCTAssertEqual(observed.generationDelta, expectedDelta, "\(scenario)")
            XCTAssertEqual(observed.commands, scenario == .success ? 1 : 0, "\(scenario)")
        }
    }

    private func assertFields(_ observed: Observation, branch: String?, offsets: [String: Int],
                              file: StaticString = #filePath, line: UInt = #line) {
        var expected = ["clipboard_start_count": String(observed.start)]
        for (stage, offset) in offsets { expected["clipboard_\(stage)_count"] = String(observed.start + offset) }
        expected["clipboard_changed_at"] = branch
        XCTAssertEqual(observed.event.filter { $0.key.hasPrefix("clipboard_") }, expected, file: file, line: line)
        XCTAssertEqual(observed.event["outcome"], branch == nil ? "completed" : "clipboard_changed", file: file, line: line)
    }

    private func run(_ scenario: Scenario) -> Observation {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func write(_ text: String, rich: Bool = false) {
            board.clearContents()
            let first = NSPasteboardItem(), second = NSPasteboardItem()
            first.setData(Data(text.utf8), forType: .string)
            if rich {
                first.setData(Data("{\\rtf1\\ansi ORIGINAL_BYTES}".utf8), forType: .rtf)
                first.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
                second.setData(Data([0, 255, 42]), forType: .init("dyn.clipboard-diagnostic-test"))
            }
            XCTAssertTrue(board.writeObjects(rich ? [first, second] : [first]))
        }
        write("ORIGINAL_CLIPBOARD_SENTINEL", rich: true)
        let original = contents(board), start = board.changeCount
        let snapshot = SelectionPasteboardSnapshot.readOnMain(name: board.name.rawValue)!
        var foreign: [[Data]] = []
        func outsideWrite() { write(Self.foreignText, rich: true); foreign = contents(board) }
        let app = SelectionFocusAX.AppIdentity(pid: 4242, startTime: 1)
        var frontmost = app
        let ax = SelectionFocusAX(secureInputEnabled: { false }, trusted: { true },
            queryFocus: { (.success, .init(role: "AXTextArea", subrole: nil)) },
            frontmostApp: { frontmost }, isChromiumFamily: { _ in true },
            setManualAccessibility: { _ in XCTFail("no recovery"); return .failure },
            sleep: { _ in XCTFail("no recovery wait") }, bundleIdentifier: { _ in "com.t3tools.t3code" })
        var copies = 0, restores = 0, time = 0.0
        let capture = SpeakSelectionCapture(focusAX: ax, snapshotReader: {
            if scenario == .preCopySnapshot { DispatchQueue.main.sync { outsideWrite() } }
            return snapshot
        }, writeRestoredItems: { items in
            restores += 1
            if scenario == .restore {
                XCTAssertTrue(board.writeObjects([items[0]]))
                outsideWrite()
                return false
            }
            return scenario == .restoreFailed ? false : board.writeObjects(items)
        }, readAXSelection: { Self.axText }, pasteboard: board, postCopy: {
            copies += 1
            if scenario == .copyFailed { return false }
            if scenario != .timeout { write(scenario == .empty ? "" : Self.copiedText) }
            if scenario == .pollDelta { outsideWrite() }
            return true
        }, readCopiedString: {
            let text = board.string(forType: .string)
            if scenario == .postRead { outsideWrite() }
            return text
        }, schedule: { delay, work in time += delay; work() }, now: {
            if scenario == .preCopyFocus || scenario == .focusOnly {
                frontmost = .init(pid: 4243, startTime: 2)
                if scenario == .preCopyFocus { outsideWrite() }
            }
            return time
        })
        let done = expectation(description: "\(scenario)")
        let state = VoiceState(pasteboard: board)
        state.isConnected = true
        var commands = 0
        state.sendCommand = { _ in commands += 1 }
        var events: [[String: String]] = []
        state.diagnosticLogger = { name, fields in if name == "selection_capture" { events.append(fields) } }
        var result = SelectionCaptureResult.captureFailed
        state.selectionTextCaptureHandler = { complete in
            capture.capture { result = $0; complete($0); done.fulfill() }
        }
        state.speakSelection()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(events.count, 1, "use the existing event, once")
        let event = events.first ?? [:]
        for payload in [Self.axText, Self.copiedText, Self.foreignText, "ORIGINAL_CLIPBOARD_SENTINEL", "ORIGINAL_BYTES"] {
            XCTAssertFalse(event.values.contains { $0.contains(payload) }, "no text payload in diagnostics")
        }
        return Observation(result: result, event: event, start: start, copies: copies, restores: restores,
            generationDelta: board.changeCount - start, bytes: contents(board), originalBytes: original,
            foreignBytes: foreign, commands: commands)
    }

    private func contents(_ board: NSPasteboard) -> [[Data]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.flatMap { type -> [Data] in
                let data = item.data(forType: type)
                XCTAssertNotNil(data)
                return [Data(type.rawValue.utf8), data ?? Data()]
            }
        }
    }
}
