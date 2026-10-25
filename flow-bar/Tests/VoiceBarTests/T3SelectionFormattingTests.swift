import AppKit
import ApplicationServices
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class T3SelectionFormattingTests: XCTestCase {
    private final class Host {
        static let t3 = SelectionFocusAX.AppIdentity(pid: 4242, startTime: 1_000_001)
        var app: SelectionFocusAX.AppIdentity? = Host.t3
        var bundle: String? = "com.t3tools.t3code"
        var secure = false, trusted = true
        var status: AXError = .success
        var role = "AXTextArea"
        var setter: AXError = .success
        var sets = 0
        var ax: SelectionFocusAX {
            SelectionFocusAX(secureInputEnabled: { self.secure }, trusted: { self.trusted },
                queryFocus: { (self.status, self.status == .success ? .init(role: self.role, subrole: nil) : nil) },
                frontmostApp: { self.app }, isChromiumFamily: { _ in true },
                setManualAccessibility: { _ in self.sets += 1; return self.setter }, sleep: { _ in },
                bundleIdentifier: { _ in self.bundle })
        }
    }

    // Public synthetic sample used by native132/135; Copy omitted only the source's final LF.
    private static let structured = """
### Orchard route

An orchard route follows three stops.

1. Pick up the blue basket.
2. Walk to the garden gate.
3. Follow the path past the old apple tree and continue beside the low stone wall. At the wooden bridge, look for a yellow sign pointing toward the pond. Keep walking until the path bends around a patch of lavender, then stop by the bench beneath the chestnut tree. Set the basket down, check that the gate behind you is closed, and take a moment to look across the water. This longer stop belongs to the same route, but it should have enough room to read without running into either of the short items above.

That completes the orchard route.
"""
    private static let flattened = String(structured.dropFirst(4)).replacingOccurrences(of: "\n", with: "")

    func testT3PrefersStructuredCopyOverNonemptyAXAndRestoresAllRepresentationsOrTrueEmpty() {
        for empty in [false, true] {
            let board = makeBoard(empty: empty)
            defer { board.releaseGlobally() }
            let original = contents(board)
            var copies = 0
            let host = Host()
            let capture = makeCapture(host, board: board, postCopy: {
                copies += 1
                board.clearContents()
                board.setString(Self.structured, forType: .string)
                return true
            })
            let result = run(capture)
            XCTAssertEqual(Self.flattened.utf16.count, 646)
            XCTAssertEqual(result.outcome, .completed)
            XCTAssertEqual(result.text.map { Array($0.utf8) }, Array(Self.structured.utf8))
            XCTAssertEqual(result.path, .copy)
            XCTAssertEqual(result.diagnosticDetails["ax_read"], "text")
            XCTAssertEqual(result.diagnosticDetails["utf16_count"], "658")
            XCTAssertEqual(result.diagnosticDetails["line_breaks"], "8")
            XCTAssertEqual(result.diagnosticDetails["list_marker_lines"], "3")
            XCTAssertFalse(result.diagnosticDetails.values.contains { $0.contains("Orchard") })
            XCTAssertEqual(copies, 1)
            XCTAssertEqual(host.sets, 0)
            XCTAssertEqual(contents(board), original)
        }
    }

    func testOtherBundleIdentifiersKeepAXFirstWithoutSnapshotOrCopy() {
        for bundle: String? in ["com.t3tools.t3code.beta", "com.example.editor", nil] {
            let host = Host()
            host.bundle = bundle
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let original = contents(board), generation = board.changeCount
            let result = run(makeCapture(host, board: board, afterSnapshot: { XCTFail("AX must not snapshot") }))
            XCTAssertEqual(result.text, Self.flattened)
            XCTAssertEqual(result.path, .ax)
            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(contents(board), original)
        }
    }

    func testT3RefusesFocusSwitchAndReusedPIDDuringSnapshotAndImmediatelyBeforeCopy() {
        for duringSnapshot in [true, false] {
            for replacement in [SelectionFocusAX.AppIdentity(pid: 5353, startTime: 2_000_002),
                                SelectionFocusAX.AppIdentity(pid: Host.t3.pid, startTime: Host.t3.startTime + 1)] {
                let host = Host()
                let board = makeBoard()
                defer { board.releaseGlobally() }
                let original = contents(board)
                let result = run(makeCapture(host, board: board, afterSnapshot: {
                    if duringSnapshot { host.app = replacement }
                }, now: {
                    // copyAndPoll starts its deadline after the snapshot/main recheck, before Cmd+C.
                    if !duringSnapshot { host.app = replacement }
                    return 0
                }))
                XCTAssertEqual(result.outcome, .captureFailed)
                XCTAssertNil(result.text)
                XCTAssertEqual(result.diagnosticDetails["copy_attempted"], "false")
                XCTAssertEqual(contents(board), original)
            }
        }
    }

    func testT3PreferenceDoesNotGrantUnreadableFocusExemptionOrBypassAdmission() {
        for scenario in ["secure", "role", "untrusted", "setter-failed", "late-unreadable", "late-secure", "late-untrusted"] {
            let host = Host()
            if scenario == "secure" { host.secure = true }
            if scenario == "role" { host.role = "AXSecureTextField" }
            if scenario == "untrusted" { host.trusted = false }
            if scenario == "setter-failed" { host.status = .noValue; host.setter = .failure }
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let original = contents(board), generation = board.changeCount
            let result = run(makeCapture(host, board: board, afterSnapshot: {
                if scenario == "late-unreadable" { host.status = .noValue }
                if scenario == "late-secure" { host.secure = true }
                if scenario == "late-untrusted" { host.trusted = false }
            }))
            XCTAssertEqual(result.outcome, ["secure", "role", "late-secure"].contains(scenario) ? .secureField : .captureFailed, scenario)
            XCTAssertNil(result.text)
            XCTAssertEqual(result.diagnosticDetails["copy_attempted"], "false", scenario)
            XCTAssertEqual(host.sets, scenario == "setter-failed" ? 1 : 0, scenario)
            XCTAssertEqual(board.changeCount, generation, scenario)
            XCTAssertEqual(contents(board), original, scenario)
        }
    }

    func testT3CanStillUseLegitimatelyEarnedUnreadableFocusCopyExemption() {
        let host = Host()
        host.status = .cannotComplete
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let original = contents(board)
        let result = run(makeCapture(host, board: board, postCopy: {
            board.clearContents()
            board.setString(Self.structured, forType: .string)
            return true
        }))
        XCTAssertEqual(result.text, Self.structured)
        XCTAssertEqual(result.diagnosticDetails["ax_read"], "not_attempted")
        XCTAssertEqual(host.sets, 1)
        XCTAssertEqual(contents(board), original)
    }

    func testT3CopyFailuresNeverReturnFlattenedAXOrOverwriteForeignClipboard() {
        for scenario in ["timeout", "failed", "empty", "race", "read-race", "snapshot-race", "snapshot-failed"] {
            let host = Host()
            let board = makeBoard()
            defer { board.releaseGlobally() }
            let original = contents(board)
            var time = 0.0, copies = 0
            let foreign = "synthetic foreign copy"
            let result = run(makeCapture(host, board: board, snapshotFails: scenario == "snapshot-failed", afterSnapshot: {
                if scenario == "snapshot-race" { board.clearContents(); board.setString(foreign, forType: .string) }
            }, postCopy: {
                copies += 1
                if ["timeout", "failed"].contains(scenario) { return scenario != "failed" }
                board.clearContents()
                board.setString(scenario == "empty" ? "" : Self.structured, forType: .string)
                if scenario == "race" { board.clearContents(); board.setString(foreign, forType: .string) }
                return true
            }, readCopiedString: {
                let text = board.string(forType: .string)
                if scenario == "read-race" { board.clearContents(); board.setString(foreign, forType: .string) }
                return text
            }, schedule: { delay, work in time += delay; work() }, now: { time }))
            let expected: SelectionCaptureResult.Outcome = scenario.contains("race") ? .clipboardChanged
                : scenario == "timeout" ? .copyTimedOut : scenario == "failed" ? .copyFailed
                : scenario == "snapshot-failed" ? .captureFailed : .copyEmpty
            XCTAssertEqual(result.outcome, expected, scenario)
            XCTAssertNil(result.text, scenario)
            XCTAssertEqual(copies, scenario.hasPrefix("snapshot-") ? 0 : 1, scenario)
            if scenario.contains("race") { XCTAssertEqual(board.string(forType: .string), foreign, scenario) }
            else { XCTAssertEqual(contents(board), original, scenario) }
            if scenario == "timeout" { XCTAssertEqual(time, 0.4, accuracy: 0.0001) }
        }
    }

    func testExplicitReadClipboardInT3StillDoesNotSnapshotCopyOrRestore() {
        let host = Host()
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let original = contents(board), generation = board.changeCount
        let capture = makeCapture(host, board: board, afterSnapshot: { XCTFail("explicit read must not snapshot") })
        let done = expectation(description: "explicit T3 clipboard read")
        capture.readClipboard(isCurrent: { true }) { result in
            XCTAssertEqual(result.text, "synthetic original")
            XCTAssertEqual(result.path, .clipboard)
            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(self.contents(board), original)
            XCTAssertEqual(host.sets, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testPreCopyFocusMismatchPreservesOriginalOrForeignGenerationForBothGuards() {
        for earnedExemption in [false, true] {
            for duringSnapshot in [true, false] {
                for foreignCopy in [false, true] {
                    let host = Host()
                    if earnedExemption { host.status = .cannotComplete }
                    let board = makeBoard()
                    defer { board.releaseGlobally() }
                    var expectedGeneration = board.changeCount
                    var expectedContents = contents(board)
                    var copies = 0
                    let switchFocus = {
                        host.app = .init(pid: 5353, startTime: 2_000_002)
                        if foreignCopy {
                            board.clearContents()
                            board.setString("synthetic foreign copy", forType: .string)
                        }
                        expectedGeneration = board.changeCount
                        expectedContents = self.contents(board)
                    }
                    let result = run(makeCapture(host, board: board, afterSnapshot: {
                        if duringSnapshot { switchFocus() }
                    }, postCopy: {
                        copies += 1
                        return false
                    }, now: {
                        if !duringSnapshot { switchFocus() }
                        return 0
                    }))
                    XCTAssertEqual(result.outcome, foreignCopy ? .clipboardChanged : .captureFailed)
                    XCTAssertNil(result.text)
                    XCTAssertEqual(result.diagnosticDetails["copy_attempted"], "false")
                    XCTAssertEqual(copies, 0, "focus failure must precede postCopy")
                    XCTAssertEqual(board.changeCount, expectedGeneration, "no clear or rewrite before Copy")
                    XCTAssertEqual(contents(board), expectedContents, "preserve every representation and item order")
                    XCTAssertEqual(host.sets, earnedExemption ? 1 : 0)
                }
            }
        }
    }

    private func makeCapture(_ host: Host, board: NSPasteboard, snapshotFails: Bool = false,
                             afterSnapshot: @escaping () -> Void = {}, postCopy: @escaping () -> Bool = {
                                 XCTFail("must not synthesize Copy"); return false
                             }, readCopiedString: (() -> String?)? = nil,
                             schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in
                                 XCTFail("unexpected polling")
                             }, now: @escaping () -> TimeInterval = { 0 }) -> SpeakSelectionCapture {
        let snapshot = SelectionPasteboardSnapshot.readOnMain(name: board.name.rawValue)
        XCTAssertNotNil(snapshot)
        return SpeakSelectionCapture(focusAX: host.ax, snapshotReader: {
            DispatchQueue.main.sync(execute: afterSnapshot)
            return snapshotFails ? nil : snapshot
        }, readAXSelection: { Self.flattened }, pasteboard: board, postCopy: postCopy,
           readCopiedString: readCopiedString, schedule: schedule, now: now)
    }

    private func run(_ capture: SpeakSelectionCapture) -> SelectionCaptureResult {
        var result: SelectionCaptureResult = .captureFailed
        let done = expectation(description: "T3 selection captured")
        capture.capture { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }

    private func makeBoard(empty: Bool = false) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        if !empty {
            let first = NSPasteboardItem(), second = NSPasteboardItem()
            first.setData(Data("synthetic original".utf8), forType: .string)
            first.setData(Data("{\\rtf1\\ansi synthetic original}".utf8), forType: .rtf)
            first.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
            second.setData(Data([0, 255, 42]), forType: .init("dyn.t3-selection-fixture"))
            XCTAssertTrue(board.writeObjects([first, second]))
        }
        return board
    }

    private func contents(_ board: NSPasteboard) -> [[Data]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.flatMap { type -> [Data] in
                let data = item.data(forType: type)
                XCTAssertNotNil(data, "the fixture must expose every advertised representation")
                return [Data(type.rawValue.utf8), data ?? Data()]
            }
        }
    }
}
