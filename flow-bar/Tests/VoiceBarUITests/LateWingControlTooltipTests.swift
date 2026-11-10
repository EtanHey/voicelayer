import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// X16/X21 (Etan J4): a control that the daemon inserts into the recording row after the wing exists (mute on `ptt`,
/// Lock on `vad`) must not carry its own insertion transition. With `VoiceBarNotchWingContentEntry.transition` on the
/// late mute control, AppKit never showed its tooltip on the M4 while Stop and Cancel did (live bisection, X16). AppKit
/// tooltip display cannot be observed offscreen, so the source rule is the regression pin; the drawn-view tests check
/// each late control registers its tooltip in the real event order.
@MainActor
final class LateWingControlTooltipTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private struct ExtractionFailure: Error, CustomStringConvertible {
        let description: String
    }

    private func barViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `{ ... }` block opened by the first `{` at or after `start`, braces matched outside string literals and
    /// comments. An unmatched block throws, so a parse failure fails the test instead of skipping it (R867 P3).
    private func block(in source: String, from start: String.Index) throws -> Range<String.Index> {
        enum Mode { case code, string, lineComment, blockComment }
        var mode = Mode.code
        var depth = 0
        var opening: String.Index?
        var index = start
        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            let following = next < source.endIndex ? source[next] : " "
            switch mode {
            case .code:
                if character == "\"" { mode = .string }
                else if character == "/", following == "/" { mode = .lineComment }
                else if character == "/", following == "*" { mode = .blockComment }
                else if character == "{" {
                    if opening == nil { opening = index }
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let opening { return opening ..< next }
                    if depth < 0 { throw ExtractionFailure(description: "unbalanced closing brace") }
                }
            case .string:
                if character == "\\" { index = next < source.endIndex ? source.index(after: next) : next; continue }
                if character == "\"" { mode = .code }
            case .lineComment:
                if character == "\n" { mode = .code }
            case .blockComment:
                if character == "*", following == "/" { mode = .code; index = source.index(after: next); continue }
            }
            index = next
        }
        throw ExtractionFailure(description: "no balanced block")
    }

    /// The recording case of the leading wing: from `case .recording:` to the next `case` of the same switch.
    private func recordingLeadingCase(_ source: String) throws -> Substring {
        guard let content = source.range(of: "private var notchLeadingContent: some View") else {
            throw ExtractionFailure(description: "notchLeadingContent not found")
        }
        let body = try block(in: source, from: content.upperBound)
        guard let recording = source.range(of: "case .recording:", range: body) else {
            throw ExtractionFailure(description: "the leading wing's recording case not found")
        }
        guard let end = source.range(of: "\n        case .", range: recording.upperBound ..< body.upperBound) else {
            throw ExtractionFailure(description: "the recording case has no following case")
        }
        return source[recording.lowerBound ..< end.lowerBound]
    }

    /// Every conditional block in the recording row that inserts a control (a `notchButton`), with its condition.
    private func lateControls(_ source: String) throws -> [(condition: String, body: Substring)] {
        let recording = try recordingLeadingCase(source)
        var found: [(String, Substring)] = []
        var cursor = recording.startIndex
        while let match = source.range(of: #"\n\s*if [^\n{]+\{"#, options: .regularExpression,
                                        range: cursor ..< recording.endIndex) {
            let condition = source[match].trimmingCharacters(in: .whitespacesAndNewlines)
            let range = try block(in: source, from: source.index(before: match.upperBound))
            if source[range].contains("notchButton(") { found.append((condition, source[range])) }
            cursor = match.upperBound
        }
        return found
    }

    func testNoLateInsertedRecordingControlCarriesAnInsertionTransition() throws {
        let controls = try lateControls(try barViewSource())
        let conditions = controls.map(\.condition)
        XCTAssertTrue(conditions.contains { $0.contains("recordingPauseControl") }, "fixture: the mute block is found")
        XCTAssertTrue(conditions.contains { $0.contains("recordingHoldControl") }, "fixture: the Lock block is found")
        for control in controls {
            XCTAssertFalse(control.body.contains(".transition("),
                           "[X16/X21 J4] \(control.condition) inserts a control late with an insertion transition; " +
                           "AppKit then does not show its tooltip (M4)")
        }
    }

    func testTheBlockParserFailsInsteadOfSkipping() {
        let unbalanced = "if let x {\n    notchButton(icon: \"}{\")\n"
        XCTAssertThrowsError(try block(in: unbalanced, from: unbalanced.startIndex),
                             "an unmatched block must throw, never pass or skip")
        let quoted = "if let x { let s = \"}\" // }\n notchButton() }"
        XCTAssertEqual(try block(in: quoted, from: quoted.startIndex).isEmpty, false,
                       "braces inside strings and comments do not end the block")
    }

    /// The real order for Lock: the optimistic press shows Stop and Cancel; the daemon's `vad` event inserts Lock later.
    func testTheLateInsertedLockRegistersItsTooltip() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        state.record(pressToTalk: true)
        XCTAssertNil(state.recordingMode, "fixture: the optimistic press has no mode yet")
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
                                                   onOpenHistory: {}))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        func tooltips() -> [String] {
            func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
            return all(host).filter { !$0.visibleRect.isEmpty }.compactMap(\.toolTip)
        }
        settle()
        XCTAssertFalse(tooltips().contains("Lock recording"), "no Lock before the daemon confirms VAD")
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad"])
        settle()
        XCTAssertTrue(tooltips().contains("Lock recording"), "[X21 J4] the late Lock registers its tooltip")
        XCTAssertTrue(tooltips().contains("Stop recording"))
        XCTAssertTrue(tooltips().contains("Cancel recording"))
        state.setRecordingHold(true)
        settle()
        XCTAssertTrue(tooltips().contains("Unlock recording"), "[X21 J4] and its engaged form")
    }
}
