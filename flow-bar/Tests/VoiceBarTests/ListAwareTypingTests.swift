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
        /// Answers of the segment guard (captured PID frontmost, same focused element), in order; then true.
        var guardResults: [Bool] = []
        var guardChecks = 0

        func targetUnchanged() -> Bool {
            guardChecks += 1
            return guardResults.isEmpty ? true : guardResults.removeFirst()
        }

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
                                    targetUnchanged: editor.targetUnchanged,
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
                // Up to 3 stale reads per break (45 ms) fits three breaks in the read budget; the fixture's
                // Chrome Beta needed about that. A slower editor is pinned below.
                for lag in [0, 1, 3] {
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
        XCTAssertLessThanOrEqual(clock, ListAwareTyping.readBudget + ListAwareTyping.pollStep)
    }

    func testTotalWaitStaysUnderTheStallBudget() {
        let long = "Items:\n" + (1 ... 40).map { "\($0). item \($0)" }.joined(separator: "\n")
        let editor = Editor(.t3Rich, lagReads: 2)
        _ = ListAwareTyping.deliver(long, env: env(editor))
        XCTAssertLessThan(clock, ListAwareTyping.readBudget + 0.05)
        XCTAssertFalse(editor.result.contains("2. 2."), "within budget the first items are exact")
    }

    func testFocusChangeStopsBeforeTheNextSegment() {
        let editor = Editor(.t3Rich, lagReads: 0)
        editor.postResults = [.posted, .focusChanged]
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)),
                       .partial(delivered: "Here's a list of things:\n",
                                remaining: "1. Buy milk and eggs\n2. Call the plumber today\n3. Book the flights"))
        XCTAssertEqual(editor.posts.count, 2)
        let first = Editor(.t3Rich, lagReads: 0)
        first.postResults = [.focusChanged]
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(first)), .focusChanged)
        XCTAssertEqual(first.posts.count, 1)
    }

    // MARK: Round 2 (Codex T7 review)

    /// P1-1/P1-2: the manual route's post never refuses, so the segment guard is what stops a delivery
    /// whose target changed between segments, and the result is partial, not "nothing inserted".
    func testFocusChangeBetweenSegmentsOnTheManualRouteStopsAndReportsPartial() {
        let editor = Editor(.t3Rich, lagReads: 0)
        editor.guardResults = [true, true, false] // first segment, second segment, then focus moved
        let result = ListAwareTyping.deliver(Self.numbered, env: env(editor))
        guard case let .partial(delivered, remaining) = result else { return XCTFail("expected partial, got \(result)") }
        XCTAssertEqual(delivered, "Here's a list of things:\n1. Buy milk and eggs\n")
        XCTAssertEqual(remaining, "2. Call the plumber today\n3. Book the flights")
        XCTAssertEqual(delivered + remaining, Self.numbered)
        XCTAssertEqual(editor.posts.count, 2, "nothing is posted after the guard refuses")
        // The target holds the reported prefix plus only the marker the editor itself put after its last break.
        XCTAssertEqual(editor.result, delivered + "2. ")
    }

    func testEverySegmentedBatchPassesTheTargetGuard() {
        let editor = Editor(.t3Rich, lagReads: 0)
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)), .posted)
        XCTAssertEqual(editor.guardChecks, editor.posts.count)
        XCTAssertEqual(editor.posts.count, 4)
    }

    func testFallbackRemainderAlsoPassesTheGuardAndReportsPartial() {
        let editor = Editor(.t3Rich, lagReads: 10_000) // breaks never land: the rest goes as one batch
        editor.guardResults = [true, false]
        let result = ListAwareTyping.deliver(Self.numbered, env: env(editor))
        XCTAssertEqual(result, .partial(delivered: "Here's a list of things:\n",
                                        remaining: "1. Buy milk and eggs\n2. Call the plumber today\n3. Book the flights"))
        XCTAssertEqual(editor.posts.count, 1)
    }

    /// Before anything is typed, an unconfirmed target keeps the old single batch through the caller's own
    /// guard — exactly the pre-T7 route — rather than refusing.
    func testUnconfirmedTargetBeforeTheFirstSegmentKeepsTheOldSingleBatch() {
        let editor = Editor(.t3Rich, lagReads: 0)
        editor.guardResults = [false]
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env(editor)), .posted)
        XCTAssertEqual(editor.posts, [SynthesizedTyping.keystrokes(for: Self.numbered)])
    }

    func testNoListTextNeverConsultsTheSegmentGuard() {
        let editor = Editor(.t3Rich)
        editor.guardResults = [false]
        XCTAssertEqual(ListAwareTyping.deliver(Self.plain, env: env(editor)), .posted)
        XCTAssertEqual(editor.guardChecks, 0)
        XCTAssertEqual(editor.posts, [SynthesizedTyping.keystrokes(for: Self.plain)])
    }

    /// P1-3: a target whose AX never answers. The readback is off the calling thread and bounded by one
    /// deadline, so delivery returns within it and types every marker (the old plan).
    func testAReaderThatNeverReturnsEndsWithinTheDeadlineAndTypesEveryMarker() {
        let hang = DispatchSemaphore(value: 0)
        defer { for _ in 0 ..< 4 { hang.signal() } }
        for answersFirst in [false, true] {
            let editor = Editor(.t3Rich, lagReads: 0)
            var answered = false
            let reader: () -> String? = {
                if answersFirst, !answered { answered = true; return editor.readValue() }
                hang.wait()
                return nil
            }
            let env = ListAwareTyping.Environment(
                readValue: reader, post: editor.post, targetUnchanged: editor.targetUnchanged,
                sleep: { Thread.sleep(forTimeInterval: $0) }, now: { ProcessInfo.processInfo.systemUptime })
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env), .posted)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertLessThan(elapsed, ListAwareTyping.readBudget + 0.15, "answersFirst=\(answersFirst)")
            XCTAssertEqual(editor.posts.flatMap { $0 }, SynthesizedTyping.keystrokes(for: Self.numbered))
            XCTAssertEqual(editor.posts.count, answersFirst ? 2 : 1)
        }
    }

    func testReadsNeverRunOnTheCallingThread() {
        XCTAssertTrue(Thread.isMainThread)
        let editor = Editor(.t3Rich, lagReads: 1)
        var onMain = 0
        let env = ListAwareTyping.Environment(
            readValue: { if Thread.isMainThread { onMain += 1 }; return editor.readValue() },
            post: editor.post, targetUnchanged: editor.targetUnchanged,
            sleep: { Thread.sleep(forTimeInterval: $0) }, now: { ProcessInfo.processInfo.systemUptime })
        XCTAssertEqual(ListAwareTyping.deliver(Self.numbered, env: env), .posted)
        XCTAssertEqual(editor.result, Self.numbered)
        XCTAssertGreaterThan(editor.reads, 0)
        XCTAssertEqual(onMain, 0)
    }

    /// An editor slower than the read budget (5 stale reads per break, ~315 ms for three breaks): the breaks
    /// past the deadline type their marker, so the worst case is the old doubled marker, never a lost or
    /// otherwise changed character.
    func testAnEditorSlowerThanTheBudgetOnlyEverDoublesAMarker() {
        for kind in [Kind.t3Plain, .t3Rich] {
            for text in [Self.numbered, Self.bullets] {
                let editor = Editor(kind, lagReads: 5)
                XCTAssertEqual(ListAwareTyping.deliver(text, env: env(editor)), .posted)
                var collapsed = editor.result
                for marker in ["2. ", "3. ", "- "] { collapsed = collapsed.replacingOccurrences(of: marker + marker, with: marker) }
                XCTAssertEqual(collapsed, text, "\(kind)")
                XCTAssertLessThanOrEqual(clock, ListAwareTyping.readBudget + ListAwareTyping.pollStep)
                clock = 0
            }
        }
    }
}
