import AppKit
import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

/// T27: Option+F5 in an app other than T3 Code whose accessibility text lost its line breaks.
/// Uses only the capture's existing API, so it compiles on main and fails there on behaviour.
/// All fixture text is synthetic.
final class OtherAppSelectionStructureTests: XCTestCase {
    private final class Host {
        static let chat = SelectionFocusAX.AppIdentity(pid: 6161, startTime: 3_000_003)
        var app: SelectionFocusAX.AppIdentity? = Host.chat
        var bundle: String? = "com.example.synthetic-chat"
        var ax: SelectionFocusAX {
            SelectionFocusAX(secureInputEnabled: { false }, trusted: { true },
                queryFocus: { (.success, .init(role: "AXGroup", subrole: nil)) },
                frontmostApp: { self.app }, isChromiumFamily: { _ in true },
                setManualAccessibility: { _ in XCTFail("focus was readable"); return .failure }, sleep: { _ in },
                bundleIdentifier: { _ in self.bundle })
        }
    }

    static let bulletsAX = "Here is the plan for the garden weekend. • Water the tomato beds before noon."
        + " • Move the clay pots into the shed. • Sweep the stone path near the gate."
    static let bulletsCopy = "Here is the plan for the garden weekend.\n\n- Water the tomato beds before noon.\n"
        + "- Move the clay pots into the shed.\n- Sweep the stone path near the gate."
    static let bulletsSplit = "Here is the plan for the garden weekend.\n• Water the tomato beds before noon."
        + "\n• Move the clay pots into the shed.\n• Sweep the stone path near the gate."
    static let numberedAX = "Steps for a calm morning at the lake: 1. Open the cabin window. 2. Feed the two cats."
        + " 3. Make the tea before the kettle cools."
    static let numberedSplit = "Steps for a calm morning at the lake:\n1. Open the cabin window.\n2. Feed the two cats."
        + "\n3. Make the tea before the kettle cools."
    static let prose = "The well-known path runs north-east past the old mill. The score was 5 - 3 at the break,"
        + " and the second half started late. Chapter 3. is the long one."

    func testFlattenedBulletsUseCopyThatCarriesTheLineBreaksAndRestoreTheClipboard() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let original = contents(board)
        var copies = 0
        let result = run(makeCapture(host, board: board, ax: Self.bulletsAX, postCopy: {
            copies += 1
            board.clearContents()
            board.setString(Self.bulletsCopy, forType: .string)
            return true
        }))
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.text, Self.bulletsCopy)
        XCTAssertEqual(result.path, .copy)
        XCTAssertEqual(result.diagnosticDetails["copy_attempted"], "true")
        XCTAssertEqual(result.diagnosticDetails["structure_repair"], "copy")
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(contents(board), original)
    }

    func testCopyFailureOrUnstructuredCopyRebuildsLineBreaksFromInlineMarkers() {
        for scenario in ["timeout", "failed", "empty", "flat-copy", "other-letters"] {
            let host = Host()
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let original = contents(board)
            var time = 0.0
            let result = run(makeCapture(host, board: board, ax: Self.bulletsAX, postCopy: {
                if ["timeout", "failed"].contains(scenario) { return scenario != "failed" }
                board.clearContents()
                let copied = scenario == "empty" ? "" : scenario == "flat-copy" ? Self.bulletsAX
                    : "A different message entirely.\n- With its own list."
                board.setString(copied, forType: .string)
                return true
            }, schedule: { delay, work in time += delay; work() }, now: { time }))
            XCTAssertEqual(result.outcome, .completed, scenario)
            XCTAssertEqual(result.text, Self.bulletsSplit, scenario)
            XCTAssertEqual(result.path, .ax, scenario)
            XCTAssertEqual(result.diagnosticDetails["structure_repair"], "split", scenario)
            XCTAssertEqual(contents(board), original, scenario)
        }
    }

    func testFlattenedNumberedListSplitsOnlyAtCountingMarkers() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let result = run(makeCapture(host, board: board, ax: Self.numberedAX, postCopy: { false }))
        XCTAssertEqual(result.text, Self.numberedSplit)
        XCTAssertEqual(result.diagnosticDetails["structure_repair"], "split")
    }

    func testFocusSwitchBeforeCopyStillReadsTheSplitAXTextWithoutCopying() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let original = contents(board), generation = board.changeCount
        let result = run(makeCapture(host, board: board, ax: Self.bulletsAX, afterSnapshot: {
            host.app = .init(pid: 7171, startTime: 4_000_004)
        }))
        XCTAssertEqual(result.text, Self.bulletsSplit)
        XCTAssertEqual(result.diagnosticDetails["copy_attempted"], "false")
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(contents(board), original)
    }

    func testNoFrontmostAppSplitsWithoutCopy() {
        let host = Host()
        host.app = nil
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let result = run(makeCapture(host, board: board, ax: Self.bulletsAX,
                                     afterSnapshot: { XCTFail("no app to address a Copy to") }))
        XCTAssertEqual(result.text, Self.bulletsSplit)
        XCTAssertEqual(result.path, .ax)
    }

    func testClipboardRaceDuringStructureCopyIsReportedNotOverwritten() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let foreign = "synthetic foreign copy"
        let result = run(makeCapture(host, board: board, ax: Self.bulletsAX, postCopy: {
            board.clearContents()
            board.setString(Self.bulletsCopy, forType: .string)
            board.clearContents()
            board.setString(foreign, forType: .string)
            return true
        }))
        XCTAssertEqual(result.outcome, .clipboardChanged)
        XCTAssertNil(result.text)
        XCTAssertEqual(board.string(forType: .string), foreign)
    }

    /// Control: ordinary prose (hyphenated words, a minus sign, a lone "3.") never copies or changes.
    func testOrdinaryProseKeepsAXFirstWithoutSnapshotOrCopy() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let original = contents(board), generation = board.changeCount
        let result = run(makeCapture(host, board: board, ax: Self.prose,
                                     afterSnapshot: { XCTFail("AX must not snapshot") }))
        XCTAssertEqual(result.text, Self.prose)
        XCTAssertEqual(result.path, .ax)
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(contents(board), original)
    }

    /// Control: AX text that kept its line breaks is read as it is.
    func testStructuredAXTextIsReadAsIs() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let result = run(makeCapture(host, board: board, ax: Self.bulletsSplit,
                                     afterSnapshot: { XCTFail("AX must not snapshot") }))
        XCTAssertEqual(result.text, Self.bulletsSplit)
        XCTAssertEqual(result.path, .ax)
    }

    private func makeCapture(_ host: Host, board: NSPasteboard, ax: String,
                             afterSnapshot: @escaping () -> Void = {}, postCopy: @escaping () -> Bool = {
                                 XCTFail("must not synthesize Copy"); return false
                             }, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in
                                 XCTFail("unexpected polling")
                             }, now: @escaping () -> TimeInterval = { 0 }) -> SpeakSelectionCapture {
        let snapshot = SelectionPasteboardSnapshot.readOnMain(name: board.name.rawValue)
        XCTAssertNotNil(snapshot)
        return SpeakSelectionCapture(focusAX: host.ax, snapshotReader: {
            DispatchQueue.main.sync(execute: afterSnapshot)
            return snapshot
        }, readAXSelection: { ax }, pasteboard: board, postCopy: postCopy, schedule: schedule, now: now)
    }

    private func run(_ capture: SpeakSelectionCapture) -> SelectionCaptureResult {
        var result: SelectionCaptureResult = .captureFailed
        let done = expectation(description: "selection captured")
        capture.capture { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("synthetic original".utf8), forType: .string)
        item.setData(Data("{\\rtf1\\ansi synthetic original}".utf8), forType: .rtf)
        XCTAssertTrue(board.writeObjects([item]))
        return board
    }

    private func contents(_ board: NSPasteboard) -> [[Data]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.flatMap { [Data($0.rawValue.utf8), item.data(forType: $0) ?? Data()] }
        }
    }
}
