import AppKit
import ApplicationServices
import Foundation
import VoiceBarUI

/// Typed delivery that does not double a list marker the target editor inserted on its own (lane T7).
/// The plan and the readback rule are `ListContinuationTyping` (VoiceBarUI); this runs them.
///
/// Text with no line break before a list line is posted exactly as before: one batch, the same
/// `SynthesizedTyping` plan, no AX read, through `post` alone. Otherwise the plan is posted in segments that
/// each end on such a break; after each one the focused element's text is polled until the break has
/// landed, and the next line's marker is dropped only on `.editorInsertedMarker`. An unreadable element,
/// the read deadline, or a reading that is not provably either case types every remaining marker — today's
/// behaviour — so the worst case is the old double marker, never a lost character.
///
/// Round 2 (Codex T7 review):
/// - Every segmented batch first passes `targetUnchanged` (the captured PID is frontmost and its focused
///   element is the captured one), on every route. A refused batch after the first stops delivery and
///   returns `.partial` with what went in and what did not; nothing is retried into another target.
/// - Reads run off the calling (main) thread, all bounded by one hard deadline per delivery
///   (`readBudget`); past it, or while a read is stuck, every remaining break counts as unknown.
struct ListAwareTyping {
    struct Environment {
        /// The focused element's text in the target, or nil when AX cannot read it. It may block: deliver
        /// runs it on its own queue and never waits past the delivery's read deadline.
        var readValue: () -> String?
        /// Posts one batch through the caller's own guard (today's route).
        var post: ([SynthesizedKeystroke]) -> GuardedTypingResult
        /// Final target guard for segmented batches, run immediately before each one, on the calling thread.
        var targetUnchanged: () -> Bool
        var sleep: (TimeInterval) -> Void
        var now: () -> TimeInterval
        var log: (String) -> Void = { _ in }
    }

    static let pollStep: TimeInterval = 0.015
    /// One hard deadline for all of a delivery's reads, first read included. The fixture measured up to
    /// 177 ms of break waits for three breaks in Chrome Beta; past this every remaining marker is typed.
    static let readBudget: TimeInterval = 0.25

    static func deliver(_ text: String, env: Environment) -> GuardedTypingResult {
        guard let segments = ListContinuationTyping.segments(for: text) else {
            return env.post(SynthesizedTyping.keystrokes(for: text))
        }
        let started = env.now()
        let deadline = started + readBudget
        let reader = BoundedReader(env.readValue)
        guard var before = reader.read(until: deadline, now: env.now) else {
            env.log("list_aware=unreadable breaks=\(segments.count - 1)")
            return env.post(SynthesizedTyping.keystrokes(for: text))
        }
        var dropNextMarker = false
        var skipped = 0
        for (index, segment) in segments.enumerated() {
            var typed = segment.text
            if dropNextMarker, let marker = segment.leadingMarker, typed.hasPrefix(marker) {
                typed.removeFirst(marker.count)
                skipped += 1
            }
            dropNextMarker = false
            if index == 0, !env.targetUnchanged() {
                // Nothing typed yet: the old single batch through the caller's own guard, as before T7.
                env.log("list_aware=unguarded_first_segment breaks=\(segments.count - 1)")
                return env.post(SynthesizedTyping.keystrokes(for: text))
            }
            let result = index == 0 ? env.post(SynthesizedTyping.keystrokes(for: typed))
                : postSegment(typed, env: env)
            guard result == .posted else {
                env.log("list_aware=stopped result=\(result) segment=\(index)/\(segments.count) skipped=\(skipped)")
                return index == 0 ? result : partial(segments, stoppedAt: index)
            }
            guard index + 1 < segments.count, let nextMarker = segments[index + 1].leadingMarker else { break }
            switch awaitBreak(before: before, typed: typed, nextMarker: nextMarker, deadline: deadline,
                              reader: reader, env: env) {
            case let .read(reading, after):
                dropNextMarker = reading == .editorInsertedMarker
                before = after
                if reading == .unknown { return finish(segments, from: index + 1, skipped: skipped, reason: "unknown", env: env) }
            case .timedOut:
                return finish(segments, from: index + 1, skipped: skipped, reason: "timeout", env: env)
            }
        }
        env.log("list_aware=done breaks=\(segments.count - 1) skipped=\(skipped) waited_ms=\(Int((env.now() - started) * 1000))")
        return .posted
    }

    /// A segment after the first: the final target guard, then the caller's post.
    private static func postSegment(_ typed: String, env: Environment) -> GuardedTypingResult {
        guard env.targetUnchanged() else { return .focusChanged }
        return env.post(SynthesizedTyping.keystrokes(for: typed))
    }

    /// Segments before `index` went in (the editor's markers stand in for any we dropped); the rest was not
    /// typed. Beyond that prefix the target can hold only a marker the editor itself added after the last
    /// break we typed.
    private static func partial(_ segments: [ListContinuationSegment], stoppedAt index: Int) -> GuardedTypingResult {
        .partial(delivered: segments[..<index].map(\.text).joined(), remaining: segments[index...].map(\.text).joined())
    }

    private enum BreakOutcome { case read(ListContinuationReading, String), timedOut }

    /// Polls until the readback shows our line and its break (a definite reading that holds on a second
    /// read), within the delivery's read deadline.
    private static func awaitBreak(before: String, typed: String, nextMarker: String, deadline: TimeInterval,
                                   reader: BoundedReader, env: Environment) -> BreakOutcome {
        var last: (ListContinuationReading, String)?
        while env.now() < deadline {
            env.sleep(pollStep)
            guard let value = reader.read(until: deadline, now: env.now) else { continue }
            let reading = ListContinuationTyping.read(before: before, after: value, typedLine: typed, nextMarker: nextMarker)
            guard reading != .unknown else { last = nil; continue }
            if let last, last.0 == reading, last.1 == value { return .read(reading, value) }
            last = (reading, value)
        }
        if let last { return .read(last.0 == .editorInsertedMarker ? .unknown : last.0, last.1) }
        return .timedOut
    }

    /// Types every remaining segment with its marker, as before the fix.
    private static func finish(_ segments: [ListContinuationSegment], from index: Int, skipped: Int,
                               reason: String, env: Environment) -> GuardedTypingResult {
        env.log("list_aware=fallback reason=\(reason) segment=\(index)/\(segments.count) skipped=\(skipped)")
        let rest = segments[index...].map(\.text).joined()
        return postSegment(rest, env: env) == .posted ? .posted : partial(segments, stoppedAt: index)
    }

    /// Runs a possibly blocking read on its own serial queue; the caller waits only until the deadline.
    /// A read still running when its wait ends stays in flight: later reads return nil at once rather than
    /// queue behind it, so a stalled target costs this delivery at most the deadline.
    final class BoundedReader {
        private let readValue: () -> String?
        private let queue = DispatchQueue(label: "com.voicelayer.voicebar.list-readback", qos: .userInitiated)
        private let lock = NSLock()
        private var inFlight = false

        init(_ readValue: @escaping () -> String?) { self.readValue = readValue }

        func read(until deadline: TimeInterval, now: () -> TimeInterval) -> String? {
            let remaining = deadline - now()
            guard remaining > 0 else { return nil }
            lock.lock()
            guard !inFlight else { lock.unlock(); return nil }
            inFlight = true
            lock.unlock()
            let result = Box()
            let done = DispatchSemaphore(value: 0)
            queue.async { [readValue, lock] in
                let value = readValue()
                lock.lock()
                result.value = value
                self.inFlight = false
                lock.unlock()
                done.signal()
            }
            guard done.wait(timeout: .now() + remaining) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result.value
        }

        private final class Box { var value: String? }
    }

    /// The target one delivery captured: its PID, and the focused element the first successful read saw.
    /// The reader runs on the readback queue; `isUnchanged` runs on the caller's thread before each
    /// segmented post. Every AX element used gets a messaging timeout.
    final class Target {
        static let messagingTimeout: Float = 0.25

        let pid: pid_t
        private let lock = NSLock()
        private var captured: AXUIElement?
        private let frontmostPID: () -> pid_t?

        init(pid: pid_t, frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
            self.pid = pid
            self.frontmostPID = frontmostPID
        }

        private func application() -> AXUIElement {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            return app
        }

        private static func focusedElement(of app: AXUIElement) -> (AXError, AXUIElement?) {
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (status, nil) }
            let element = focused as! AXUIElement // swiftlint:disable:this force_cast
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            return (.success, element)
        }

        /// The captured PID is frontmost and its focused element is still the captured one. False when
        /// nothing was captured or AX cannot answer: a guard that cannot confirm refuses.
        func isUnchanged() -> Bool {
            guard frontmostPID() == pid else { return false }
            lock.lock()
            let captured = captured
            lock.unlock()
            guard let captured, let current = Self.focusedElement(of: application()).1 else { return false }
            return CFEqual(current, captured)
        }

        /// The focused element's AXValue. A Chromium/Electron app answers with no focus until
        /// AXManualAccessibility is set (SpeakSelectionCapture does the same), so it is set once on a miss.
        /// Nothing touches AX until the first read, which only list-shaped text makes. Never reads a
        /// secure field. The first element read is the one `isUnchanged` compares against.
        func makeReader(sleep: @escaping (TimeInterval) -> Void) -> () -> String? {
            var cachedApp: AXUIElement?
            var enabled = false
            return { [self] in
                let app = cachedApp ?? application()
                cachedApp = app
                func read() -> (AXError, String?) {
                    let (status, element) = Self.focusedElement(of: app)
                    guard let element else { return (status, nil) }
                    var role: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role) == .success,
                       role as? String == kAXSecureTextFieldSubrole as String { return (.success, nil) }
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                          let text = value as? String else { return (.success, nil) }
                    lock.lock()
                    if captured == nil { captured = element }
                    lock.unlock()
                    return (.success, text)
                }
                var (status, value) = read()
                if value == nil, !enabled, status == .noValue || status == .cannotComplete {
                    enabled = true
                    if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                        for _ in 0 ..< 4 where value == nil {
                            sleep(0.05)
                            (status, value) = read()
                        }
                    }
                }
                return value
            }
        }
    }
}
