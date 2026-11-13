import XCTest
@testable import VoiceBar
import VoiceBarUI

/// Lane T7: list-aware typed delivery against editor models of the fixture editors. Each model applies
/// posted keystrokes the way its editor does and reports AX text the way Chrome did for it.
final class ListAwareTypingTests: XCTestCase {
    enum Kind { case textarea, contentEditable, t3Plain, t3Rich, t3RichNoAX }

    final class Editor {
        let kind: Kind
        var text = ""
        var queue: [SynthesizedKeystroke] = []
        /// Reads that return the stale value before queued keystrokes land (renderer lag).
        var lagReads: Int
        var lagLeft = 0
        var posts: [[SynthesizedKeystroke]] = []
        var reads = 0
        var postResults: [GuardedTypingResult] = []

        init(_ kind: Kind, lagReads: Int = 2) { self.kind = kind; self.lagReads = lagReads }

        func post(_ plan: [SynthesizedKeystroke]) -> GuardedTypingResult {
            posts.append(plan)
            let result = postResults.isEmpty ? .posted : postResults.removeFirst()
            guard result == .posted else { return result }
            queue += plan
            lagLeft = lagReads
            return .posted
        }

        func flush() {
            for keystroke in queue {
                switch keystroke {
                case let .text(s): text += s
                case .newline:
                    let line = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
                    text += "\n"
                    if kind == .t3Plain || kind == .t3Rich || kind == .t3RichNoAX,
                       let marker = ListContinuationTyping.marker(atStartOf: line), line.count > marker.count {
                        text += Self.next(marker)
                    }
                }
            }
            queue = []
        }

        static func next(_ marker: String) -> String {
            if let n = Int(marker.dropLast(2)) { return "\(n + 1)\(marker.dropFirst(String(n).count))" }
            return marker
        }

        /// What the composer would send (T3) or the field holds.
        var result: String { flush(); return text }

        func readValue() -> String? {
            reads += 1
            if kind == .t3RichNoAX { return nil }
            if lagLeft > 0 { lagLeft -= 1 } else { flush() }
            switch kind {
            case .textarea, .t3Plain: return text
            case .contentEditable: return text.hasSuffix("\n") ? text + "\n" : text
            case .t3Rich, .t3RichNoAX:
                // T3 paints a bullet item's marker as a disc; numbered markers paint as their source.
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.hasPrefix("- ") ? "• " + $0.dropFirst(2) : String($0) }
                let painted = lines.joined(separator: "\n")
                let last = lines.last ?? ""
                return last.isEmpty || ListContinuationTyping.marker(atStartOf: last[...]) == last
                    || last == "• " ? painted + "\n" : painted
            }
        }
    }

    var clock: TimeInterval = 0

    func env(_ editor: Editor) -> ListAwareTyping.Environment {
        ListAwareTyping.Environment(readValue: editor.readValue, post: editor.post,
                                    sleep: { self.clock += $0 }, now: { self.clock })
    }

    /// What candidate 1110c did: the whole plan in one batch.
    func legacy(_ text: String, into editor: Editor) -> String {
        _ = editor.post(SynthesizedTyping.keystrokes(for: text))
        return editor.result
    }

    static let numbered = "Here's a list of things:\n1. Buy milk and eggs\n2. Call the plumber today\n3. Book the flights"
    static let bullets = "Packing list:\n- Passport and tickets\n- Phone charger\n- Sunglasses"
    static let plain = "First line of the note.\nSecond line follows here.\nThird line ends it."
    static let single = "Just one line of dictated text, nothing else."

    func testCandidateBehaviourDoublesMarkersInT3() {
        XCTAssertEqual(legacy(Self.numbered, into: Editor(.t3Rich)),
                       "Here's a list of things:\n1. Buy milk and eggs\n2. 2. Call the plumber today\n3. 3. Book the flights")
        XCTAssertEqual(legacy(Self.bullets, into: Editor(.t3Plain)),
                       "Packing list:\n- Passport and tickets\n- - Phone charger\n- - Sunglasses")
    }

    func testEveryEditorGetsExactlyTheTranscript() {
        for kind in [Kind.textarea, .contentEditable, .t3Plain, .t3Rich] {
            for text in [Self.numbered, Self.bullets, Self.plain, Self.single] {
                for lag in [0, 1, 5] {
                    let editor = Editor(kind, lagReads: lag)
                    XCTAssertEqual(ListAwareTyping.deliver(text, env: env(editor)), .posted)
                    XCTAssertEqual(editor.result, text, "\(kind) lag \(lag)")
                }
            }
        }
    }

    func testTextWithoutAListBreakIsOneBatchOfTheOldPlanWithNoRead() {
        for text in [Self.single, Self.plain, "1. one list line only"] {
            let editor = Editor(.t3Rich)
            XCTAssertEqual(ListAwareTyping.deliver(text, env: env(editor)), .posted)
            XCTAssertEqual(editor.posts, [SynthesizedTyping.keystrokes(for: text)])
            XCTAssertEqual(editor.reads, 0)
        }
    }

    func testUnreadableTargetTypesTheOldPlanInOneBatch() {
        let editor = Editor(.t3RichNoAX)
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)), .posted)
        XCTAssertEqual(editor.posts, [SynthesizedTyping.keystrokes(for: Self.numbered)])
    }

    func testPlainEditorReceivesTheSameKeystrokesAsBefore() {
        let editor = Editor(.textarea)
        _ = ListAwareTyping.deliver(Self.numbered, env: env(editor))
        XCTAssertEqual(editor.posts.flatMap { $0 }, SynthesizedTyping.keystrokes(for: Self.numbered))
    }

    func testABreakThatNeverLandsFallsBackToTypingEveryMarker() {
        let editor = Editor(.t3Rich, lagReads: 10_000)
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)), .posted)
        XCTAssertEqual(editor.posts.flatMap { $0 }, SynthesizedTyping.keystrokes(for: Self.numbered))
        XCTAssertLessThanOrEqual(clock, ListAwareTyping.totalWaitBudget + ListAwareTyping.pollStep)
    }

    func testTotalWaitStaysUnderTheStallBudget() {
        let long = "Items:\n" + (1 ... 40).map { "\($0). item \($0)" }.joined(separator: "\n")
        let editor = Editor(.t3Rich, lagReads: 20)
        _ = ListAwareTyping.deliver(long, env: env(editor))
        XCTAssertLessThan(clock, ListAwareTyping.totalWaitBudget + 0.05)
        XCTAssertFalse(editor.result.contains("2. 2."), "within budget the first items are exact")
    }

    func testFocusChangeStopsBeforeTheNextSegment() {
        let editor = Editor(.t3Rich, lagReads: 0)
        editor.postResults = [.posted, .focusChanged]
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)), .focusChanged)
        XCTAssertEqual(editor.posts.count, 2)
        let first = Editor(.t3Rich, lagReads: 0)
        first.postResults = [.focusChanged]
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(first)), .focusChanged)
        XCTAssertEqual(first.posts.count, 1)
    }
}
