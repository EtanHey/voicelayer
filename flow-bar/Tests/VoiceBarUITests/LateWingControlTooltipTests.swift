import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// X16/X21 (Etan J4): a tooltip-bearing wing control that appears conditionally must not carry its own insertion
/// transition. With `VoiceBarNotchWingContentEntry.transition` on the late mute control, AppKit never showed its tooltip
/// on the M4 while Stop and Cancel did (live bisection, X16); Lock had the same shape (X21). AppKit tooltip display
/// cannot be observed offscreen, so this is a source rule.
///
/// R868 P2: the first version scanned only the recording case and one-line `if` headers, so the queue Next, Forward,
/// Show teleprompter and any two-line condition escaped it. This version scans every wing builder reachable from the
/// two wing roots (plus the reading row helper that inserts Stop), finds every tooltip-bearing control (the primitives
/// and every helper whose body registers a tooltip, transitively), and checks an explicit inventory of the conditional
/// ones: an unlisted conditional control, a stale listing, an entry transition on a control or on a wrapper inside its
/// branch, or any parse failure fails the test. The whole recording row's transition and the non-control spinners'
/// transitions stay allowed.
@MainActor
final class LateWingControlTooltipTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    // MARK: The inventory

    /// Every conditionally inserted, tooltip-bearing wing control, as `member|control|label` with its count. A control
    /// in a branch (`if`, `else`, `guard`, or a `switch` case) is conditional. Update this list when a wing control is
    /// added or moved; the test fails until it matches the source.
    static let conditionalControls: [String: Int] = [
        // Leading wing: launcher (switch case).
        #"notchLeadingContent|notchButton|"Start voice recording""#: 1,
        "notchLeadingContent|microphonePickerButton|": 3,
        // Leading wing: recording (switch case, and the two late controls).
        #"notchLeadingContent|notchButton|"Stop recording""#: 1,
        "notchLeadingContent|notchButton|recordingPauseControl.accessibilityLabel": 1,
        #"notchLeadingContent|notchButton|"Cancel recording""#: 1,
        "notchLeadingContent|notchButton|recordingHoldControl.accessibilityLabel": 1,
        // Leading wing: the status icon (a helper whose own branch inserts the New recording / Start control).
        "notchLeadingContent|statusIcon|": 2,
        #"statusIcon|notchButton|state.mode == .error ? "New recording" : "Start voice recording""#: 1,
        // Leading wing: compact status / teleprompter branches.
        "notchLeadingContent|readingTransportControls|playbackPauseControl": 1,
        "notchLeadingContent|playbackLeadingControls|nil": 1,
        // Reading leading helpers.
        "playbackLeadingControls|playbackPauseButton|pause": 1,
        "playbackLeadingControls|notchButton|readQueueControl.accessibilityLabel": 1,
        #"readingTransportControls|notchButton|"Next read""#: 1,
        // Trailing wing.
        "notchTrailingContent|historyButton|": 1,
        "notchTrailingContent|settingsButton|": 1,
        "notchTrailingContent|notchSpeakingTrailingContent|": 1,
        "notchTrailingContent|notchCompactStatusContent|": 1,
        "notchCompactStatusContent|historyButton|": 1,
        "notchCompactStatusContent|settingsButton|": 1,
        "notchCompactStatusContent|notchSpeakingTrailingContent|": 1,
        #"notchCompactStatusContent|notchButton|"Dismiss error""#: 1,
        #"notchSpeakingTrailingContent|notchTeleprompterButton|"Show teleprompter""#: 1,
        // The reading row helper inserts Stop only while collapsed.
        "VoiceBarReadingTrailingRow|stop|": 1,
    ]

    // MARK: Tests

    func testEveryConditionalWingControlIsListedAndNoneCarriesAnInsertionTransition() throws {
        let report = try Self.scan(barView: try source("Sources/VoiceBarUI/BarView.swift"),
                                   wingControls: try source("Sources/VoiceBarUI/VoiceBarWingControls.swift"))
        XCTAssertGreaterThanOrEqual(report.members.count, 8, "fixture: the wing builders are found (\(report.members))")
        for member in ["notchLeadingContent", "notchTrailingContent", "notchCompactStatusContent",
                       "notchSpeakingTrailingContent", "playbackLeadingControls", "readingTransportControls"] {
            XCTAssertTrue(report.members.contains(member), "fixture: \(member) is in the wing scope")
        }
        let unlisted = report.conditional.filter { Self.conditionalControls[$0.key] != $0.value }.sorted { $0.key < $1.key }
        let stale = Self.conditionalControls.filter { report.conditional[$0.key] != $0.value }.sorted { $0.key < $1.key }
        XCTAssertEqual(report.conditional, Self.conditionalControls,
                       "[X21] the inventory of conditional wing controls is stale; update `conditionalControls`. " +
                       "Found but not listed (or a different count): \(unlisted). Listed but not found: \(stale)")
        XCTAssertEqual(report.violations, [],
                       "[X16/X21 J4] a tooltip-bearing wing control carries an insertion transition; AppKit then does " +
                       "not show its tooltip (M4)")
    }

    /// R868 miss 1: the queue Next control (a reading-wing helper) with the entry transition must fail.
    func testFixtureQueueNextWithAnInsertionTransitionFails() throws {
        let mutated = try mutate(try source("Sources/VoiceBarUI/BarView.swift"),
                                 after: "state.skipToNextRead()\n                }",
                                 insert: "\n                .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))")
        let report = try Self.scan(barView: mutated, wingControls: try source("Sources/VoiceBarUI/VoiceBarWingControls.swift"))
        XCTAssertTrue(report.violations.contains { $0.contains("readQueueControl.accessibilityLabel") },
                      "the queue Next transition is caught: \(report.violations)")
    }

    /// R868 miss 2: a new control under a two-line condition, with the entry transition, must fail twice over: it is
    /// unlisted, and it carries the transition.
    func testFixtureTwoLineConditionIsCaught() throws {
        let fixture = """

                        if state.isConnected,
                           state.mode == .recording {
                            notchButton(icon: "circle", accessibilityLabel: "Fixture control") {
                                state.dismissError()
                            }
                            .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))
                        }
        """
        let mutated = try mutate(try source("Sources/VoiceBarUI/BarView.swift"),
                                 after: "commandRouter.handleCancel()\n                }", insert: fixture)
        let report = try Self.scan(barView: mutated, wingControls: try source("Sources/VoiceBarUI/VoiceBarWingControls.swift"))
        XCTAssertEqual(report.conditional[#"notchLeadingContent|notchButton|"Fixture control""#], 1,
                       "the two-line conditional control is discovered")
        XCTAssertNotEqual(report.conditional, Self.conditionalControls, "an unlisted control makes the inventory stale")
        XCTAssertTrue(report.violations.contains { $0.contains("Fixture control") }, "\(report.violations)")
    }

    /// Restoring either removed transition fails, and a transition on a wrapper inside a branch fails too.
    func testFixtureRestoredLockMuteAndWrapperTransitionsFail() throws {
        let bar = try source("Sources/VoiceBarUI/BarView.swift")
        let helper = try source("Sources/VoiceBarUI/VoiceBarWingControls.swift")
        let transition = "\n                    .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))"
        let lock = try Self.scan(barView: try mutate(bar, after: "state.setRecordingHold(!state.isRecordingHoldEngaged)\n                    }",
                                                     insert: transition), wingControls: helper)
        XCTAssertTrue(lock.violations.contains { $0.contains("recordingHoldControl") }, "\(lock.violations)")
        let mute = try Self.scan(barView: try mutate(bar, after: ".contentTransition(.symbolEffect(.replace))",
                                                     insert: transition), wingControls: helper)
        XCTAssertTrue(mute.violations.contains { $0.contains("recordingPauseControl") }, "\(mute.violations)")
        let wrapped = try mutate(bar, after: "            ZStack(alignment: .trailing) {\n                notchWaveform\n                    .opacity(showsReveal ? 0 : 1)\n                if showsReveal {",
                                 insert: "\n                    Group {")
        let wrapper = try Self.scan(barView: try mutate(wrapped, after: "state.showTeleprompter()\n                    }",
                                                        insert: "\n                    }.transition(VoiceBarNotchWingContentEntry.transition(growth: 0))"),
                                    wingControls: helper)
        XCTAssertTrue(wrapper.violations.contains { $0.contains("Show teleprompter") }, "\(wrapper.violations)")
    }

    func testTheScannerFailsInsteadOfSkipping() {
        XCTAssertThrowsError(try SourceScanner("var x: some View { notchButton(icon: \"}{\") "), "unbalanced must throw")
        XCTAssertThrowsError(try SourceScanner("var x: some View { foo(] }"), "mismatched must throw")
        XCTAssertNoThrow(try SourceScanner("var x: some View { let s = \"}\" // }\n /* { */ foo() }"),
                         "braces in strings and comments are ignored")
        XCTAssertThrowsError(try Self.scan(barView: "struct Nothing {}", wingControls: "struct Nothing {}"),
                             "missing wing roots throw")
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

    // MARK: Helpers

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func mutate(_ source: String, after anchor: String, insert: String) throws -> String {
        guard let range = source.range(of: anchor) else { throw ScanFailure("fixture anchor not found: \(anchor)") }
        var copy = source
        copy.insert(contentsOf: insert, at: range.upperBound)
        return copy
    }

    struct ScanFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Report {
        var members: Set<String> = []
        var conditional: [String: Int] = [:]
        var violations: [String] = []
    }

    static let entryTransition = ".transition(VoiceBarNotchWingContentEntry"
    static let primitives = ["notchButton", "notchTeleprompterButton", "VoiceBarPillControlButton"]
    static let tooltipMarkers = ["notchButton(", "notchTeleprompterButton(", "VoiceBarPillControlButton(", "PillControlTooltip("]

    /// Scans the wing builders reachable from `notchLeadingContent` and `notchTrailingContent`, and the reading row helper.
    static func scan(barView: String, wingControls: String) throws -> Report {
        var report = Report()
        let bar = try SourceScanner(barView)
        let members = bar.members()
        guard members["notchLeadingContent"] != nil, members["notchTrailingContent"] != nil else {
            throw ScanFailure("the wing roots notchLeadingContent / notchTrailingContent were not found")
        }
        // Tooltip-bearing helpers, transitively: a member whose body registers a tooltip or uses another such helper.
        var controls = Set(primitives)
        var changed = true
        while changed {
            changed = false
            for (name, body) in members where !controls.contains(name) {
                let text = bar.text(body)
                if tooltipMarkers.contains(where: text.contains) || controls.contains(where: { bar.references($0, in: body) }) {
                    controls.insert(name); changed = true
                }
            }
        }
        // Wing scope: every member reachable from the two roots.
        var scope: Set<String> = ["notchLeadingContent", "notchTrailingContent"]
        var frontier = Array(scope)
        while let name = frontier.popLast(), let body = members[name] {
            for other in members.keys where !scope.contains(other) && bar.references(other, in: body) {
                scope.insert(other); frontier.append(other)
            }
        }
        report.members = scope
        for name in scope.sorted() {
            guard let body = members[name] else { continue }
            for token in controls where token != name {
                bar.check(token: token, in: body, member: name, report: &report)
            }
        }
        // The reading row helper inserts its `stop` content conditionally.
        let helper = try SourceScanner(wingControls)
        guard let row = helper.structBody("VoiceBarReadingTrailingRow") else {
            throw ScanFailure("VoiceBarReadingTrailingRow's body was not found")
        }
        helper.check(token: "stop", in: row, member: "VoiceBarReadingTrailingRow", report: &report)
        return report
    }
}

/// A Swift source in UTF-16 with its brackets matched outside strings and comments. Any imbalance throws.
struct SourceScanner {
    let units: [UInt16]
    let string: NSString
    private(set) var pair: [Int: Int] = [:]
    private(set) var code: [Bool]
    /// Each `{` block: its open and close offsets and the statement text before it.
    private(set) var blocks: [(open: Int, close: Int, header: String)] = []

    init(_ source: String) throws {
        string = source as NSString
        units = Array(source.utf16)
        code = Array(repeating: false, count: units.count)
        enum Mode { case code, string, multiString, lineComment, blockComment }
        var mode = Mode.code
        var stack: [Int] = []
        var lastBoundary = -1
        var openHeaders: [Int: String] = [:]
        var i = 0
        func at(_ k: Int) -> UInt16 { k < units.count ? units[k] : 0 }
        let quote: UInt16 = 34, slash: UInt16 = 47, star: UInt16 = 42, backslash: UInt16 = 92, newline: UInt16 = 10
        while i < units.count {
            let c = units[i]
            switch mode {
            case .code:
                if c == quote, at(i + 1) == quote, at(i + 2) == quote { mode = .multiString; i += 3; continue }
                if c == quote { mode = .string; i += 1; continue }
                if c == slash, at(i + 1) == slash { mode = .lineComment; i += 2; continue }
                if c == slash, at(i + 1) == star { mode = .blockComment; i += 2; continue }
                code[i] = true
                switch c {
                case 123, 40, 91: // { ( [
                    if c == 123 {
                        openHeaders[i] = string.substring(with: NSRange(location: lastBoundary + 1, length: i - lastBoundary - 1))
                        lastBoundary = i
                    }
                    stack.append(i)
                case 125, 41, 93: // } ) ]
                    guard let open = stack.popLast() else { throw LateWingControlTooltipTests.ScanFailure("unbalanced \(c) at \(i)") }
                    let expected: UInt16 = c == 125 ? 123 : c == 41 ? 40 : 91
                    guard units[open] == expected else { throw LateWingControlTooltipTests.ScanFailure("mismatched bracket at \(i)") }
                    pair[open] = i; pair[i] = open
                    if c == 125 {
                        blocks.append((open, i, openHeaders[open] ?? ""))
                        lastBoundary = i
                    }
                default: break
                }
            case .string:
                if c == backslash { i += 2; continue }
                if c == quote || c == newline { mode = .code }
            case .multiString:
                if c == backslash { i += 2; continue }
                if c == quote, at(i + 1) == quote, at(i + 2) == quote { mode = .code; i += 3; continue }
            case .lineComment:
                if c == newline { mode = .code }
            case .blockComment:
                if c == star, at(i + 1) == slash { mode = .code; i += 2; continue }
            }
            i += 1
        }
        guard stack.isEmpty, mode != .string, mode != .multiString, mode != .blockComment else {
            throw LateWingControlTooltipTests.ScanFailure("unterminated bracket, string or comment")
        }
    }

    func text(_ range: Range<Int>) -> String { string.substring(with: NSRange(location: range.lowerBound, length: range.count)) }

    /// `var name: some View {` / `func name(...) -> some View {` bodies, by name.
    func members() -> [String: Range<Int>] {
        var result: [String: Range<Int>] = [:]
        let regex = try! NSRegularExpression(pattern: #"\b(?:var|func)\s+(\w+)\b[^{;]*?some View\s*\{"#)
        for match in regex.matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
            let open = match.range.location + match.range.length - 1
            let name = string.substring(with: match.range(at: 1))
            guard name != "body", code[open], let close = pair[open] else { continue }
            result[name] = open ..< close + 1
        }
        return result
    }

    func structBody(_ name: String) -> Range<Int>? {
        let start = string.range(of: "struct \(name)")
        guard start.location != NSNotFound else { return nil }
        let body = string.range(of: "var body: some View {", range: NSRange(location: start.location,
                                                                            length: string.length - start.location))
        guard body.location != NSNotFound else { return nil }
        let open = body.location + body.length - 1
        guard let close = pair[open] else { return nil }
        return open ..< close + 1
    }

    /// Code occurrences of `name` as a whole identifier (not a declaration, not a member access) inside `range`.
    func occurrences(of name: String, in range: Range<Int>) -> [Int] {
        let regex = try! NSRegularExpression(pattern: "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: name))(?!\\w)")
        return regex.matches(in: string as String, range: NSRange(location: range.lowerBound, length: range.count))
            .map(\.range.location)
            .filter { code[$0] }
            .filter { location in
                let before = string.substring(with: NSRange(location: max(0, location - 5), length: min(5, location)))
                return !before.hasSuffix("var ") && !before.hasSuffix("func ") && !before.hasSuffix("let ")
            }
    }

    func references(_ name: String, in range: Range<Int>) -> Bool { !occurrences(of: name, in: range).isEmpty }

    private func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    private func skipSpaces(_ i: Int, newlines: Bool) -> Int {
        var j = i
        while j < units.count {
            let c = units[j]
            if c == 32 || c == 9 || (newlines && (c == 10 || c == 13)) { j += 1; continue }
            if newlines, c == 47, j + 1 < units.count, units[j + 1] == 47 { // a line comment between modifiers
                while j < units.count, units[j] != 10 { j += 1 }
                continue
            }
            break
        }
        return j
    }

    /// From just after an identifier or a closing bracket: argument lists, trailing and labeled closures.
    private func skipCallSuffixes(_ start: Int) -> Int {
        var i = start
        while true {
            let j = skipSpaces(i, newlines: false)
            guard j < units.count else { return i }
            if (units[j] == 40 || units[j] == 123), code[j], let close = pair[j] { i = close + 1; continue }
            // `} label: {`
            var k = j
            while k < units.count, isIdentifier(units[k]) { k += 1 }
            if k > j, k < units.count, units[k] == 58 {
                let brace = skipSpaces(k + 1, newlines: false)
                if brace < units.count, units[brace] == 123, let close = pair[brace] { i = close + 1; continue }
            }
            return i
        }
    }

    /// The modifier chain from `start` (an identifier, or just after a block's closing brace when `afterClose`).
    func chain(from start: Int, afterClose: Bool = false) -> Range<Int> {
        var i = start
        if !afterClose { while i < units.count, isIdentifier(units[i]) { i += 1 } }
        i = skipCallSuffixes(i)
        while true {
            let j = skipSpaces(i, newlines: true)
            guard j + 1 < units.count, units[j] == 46, isIdentifier(units[j + 1]) else { break }
            var k = j + 1
            while k < units.count, isIdentifier(units[k]) { k += 1 }
            i = skipCallSuffixes(k)
        }
        return start ..< i
    }

    /// The last statement of a block header, with multi-line conditions joined (`a,\n b {`).
    func statement(_ header: String) -> String {
        func isComment(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        var lines = header.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isComment(last) { lines.removeLast() }
        guard var statement = lines.popLast() else { return "" }
        while let previous = lines.last, !isComment(previous) {
            let trimmed = previous.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(",") || trimmed.hasSuffix("&&") || trimmed.hasSuffix("||") || trimmed.hasSuffix("(") else { break }
            statement = trimmed + " " + statement.trimmingCharacters(in: .whitespaces)
            lines.removeLast()
        }
        return statement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isBranch(_ header: String) -> Bool {
        let s = statement(header)
        return ["if ", "else", "guard ", "switch "].contains { s.hasPrefix($0) }
    }

    /// The `case ...:` label of a switch block that governs `offset`.
    func caseLabel(in block: (open: Int, close: Int, header: String), before offset: Int) -> String {
        let regex = try! NSRegularExpression(pattern: #"\bcase\s+[^:\n]+:"#)
        let labels = regex.matches(in: string as String, range: NSRange(location: block.open, length: offset - block.open))
            .filter { code[$0.range.location] && innermost(containing: $0.range.location)?.open == block.open }
        return labels.last.map { string.substring(with: $0.range) } ?? ""
    }

    func innermost(containing offset: Int) -> (open: Int, close: Int, header: String)? {
        blocks.filter { $0.open < offset && offset < $0.close }.min { $0.close - $0.open < $1.close - $1.open }
    }

    /// The label an inventory entry uses: the `accessibilityLabel:` argument, else the call's arguments, else empty.
    func label(at offset: Int, token: String) -> String {
        let after = offset + (token as NSString).length
        let open = skipSpaces(after, newlines: false)
        guard open < units.count, units[open] == 40, let close = pair[open] else { return "" }
        let arguments = text(open + 1 ..< close)
        if let range = arguments.range(of: "accessibilityLabel:") {
            var value = arguments[range.upperBound...]
            if let comma = value.firstIndex(of: ",") { value = value[..<comma] }
            return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Records each control site of `token` in `range`: conditional sites into the inventory, entry transitions as
    /// violations (on the control's own chain, or on a wrapper between it and its branch, or the member's root when
    /// unconditional), except the whole recording row.
    func check(token: String, in range: Range<Int>, member: String, report: inout LateWingControlTooltipTests.Report) {
        for offset in occurrences(of: token, in: range) {
            let signature = "\(member)|\(token)|\(label(at: offset, token: token))"
            let enclosing = blocks.filter { $0.open < offset && offset < $0.close && $0.open >= range.lowerBound }
                .sorted { $0.close - $0.open < $1.close - $1.open }
            let branch = enclosing.first { isBranch($0.header) }
            if branch != nil { report.conditional[signature, default: 0] += 1 }
            if text(chain(from: offset)).contains(LateWingControlTooltipTests.entryTransition) {
                report.violations.append("\(signature): on the control")
            }
            for wrapper in enclosing {
                if let branch, wrapper.open == branch.open { break }
                if isBranch(wrapper.header) { break }
                guard text(chain(from: wrapper.close + 1, afterClose: true))
                    .contains(LateWingControlTooltipTests.entryTransition) else { continue }
                // The whole recording row: an HStack that is the `.recording` case's content in the leading wing.
                let outer = enclosing.first { $0.open < wrapper.open && isBranch($0.header) }
                let isWholeRecordingRow = member == "notchLeadingContent" && statement(wrapper.header).hasPrefix("HStack")
                    && outer.map { statement($0.header).hasPrefix("switch ") && caseLabel(in: $0, before: wrapper.open)
                        .contains(".recording") } == true
                if !isWholeRecordingRow { report.violations.append("\(signature): on a wrapper") }
            }
        }
    }
}
