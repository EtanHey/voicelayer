import ApplicationServices
import Foundation
import VoiceBarUI

/// Typed delivery that does not double a list marker the target editor inserted on its own (lane T7).
/// The plan and the readback rule are `ListContinuationTyping` (VoiceBarUI); this runs them.
///
/// Text with no line break before a list line is posted exactly as before: one batch, the same
/// `SynthesizedTyping` plan, no AX read. Otherwise the plan is posted in segments that each end on such a
/// break; after each one the focused element's text is polled until the break has landed, and the next
/// line's marker is dropped only on `.editorInsertedMarker`. An unreadable element, a timeout, or a
/// reading that is not provably either case types every remaining marker — today's behaviour — so the
/// worst case is the old double marker, never a lost character. Each segment passes the caller's guard.
struct ListAwareTyping {
    struct Environment {
        /// The focused element's text in the target, or nil when AX cannot read it.
        var readValue: () -> String?
        /// Posts one batch through the caller's final guard.
        var post: ([SynthesizedKeystroke]) -> GuardedTypingResult
        var sleep: (TimeInterval) -> Void
        var now: () -> TimeInterval
        var log: (String) -> Void = { _ in }
    }

    static let pollStep: TimeInterval = 0.015
    static let perBreakTimeout: TimeInterval = 0.4
    /// Well below the 2 s main-loop stall threshold (RuntimeResponsivenessWatchdog), leaving room for
    /// the reader's one-time AXManualAccessibility retries (at most 0.4 s) before the first break.
    static let totalWaitBudget: TimeInterval = 1.0

    static func deliver(_ text: String, env: Environment) -> GuardedTypingResult {
        guard let segments = ListContinuationTyping.segments(for: text) else {
            return env.post(SynthesizedTyping.keystrokes(for: text))
        }
        guard var before = env.readValue() else {
            env.log("list_aware=unreadable breaks=\(segments.count - 1)")
            return env.post(SynthesizedTyping.keystrokes(for: text))
        }
        let started = env.now()
        var dropNextMarker = false
        var skipped = 0
        for (index, segment) in segments.enumerated() {
            var typed = segment.text
            if dropNextMarker, let marker = segment.leadingMarker, typed.hasPrefix(marker) {
                typed.removeFirst(marker.count)
                skipped += 1
            }
            dropNextMarker = false
            let result = env.post(SynthesizedTyping.keystrokes(for: typed))
            guard result == .posted else {
                env.log("list_aware=stopped result=\(result) segment=\(index)/\(segments.count) skipped=\(skipped)")
                return index == 0 ? result : .focusChanged
            }
            guard index + 1 < segments.count, let nextMarker = segments[index + 1].leadingMarker else { break }
            switch awaitBreak(before: before, typed: typed, nextMarker: nextMarker, started: started, env: env) {
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

    private enum BreakOutcome { case read(ListContinuationReading, String), timedOut }

    /// Polls until the readback shows our line and its break (a definite reading that holds on a second
    /// read), within the per-break and total budgets.
    private static func awaitBreak(before: String, typed: String, nextMarker: String,
                                   started: TimeInterval, env: Environment) -> BreakOutcome {
        let deadline = min(env.now() + perBreakTimeout, started + totalWaitBudget)
        var last: (ListContinuationReading, String)?
        while env.now() < deadline {
            env.sleep(pollStep)
            guard let value = env.readValue() else { continue }
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
        return env.post(SynthesizedTyping.keystrokes(for: rest)) == .posted ? .posted : .focusChanged
    }

    /// The focused element's AXValue in `pid`. A Chromium/Electron app answers with no focus until
    /// AXManualAccessibility is set (SpeakSelectionCapture does the same), so it is set once on a miss.
    /// Nothing touches AX until the first read, which only list-shaped text makes.
    static func focusedValueReader(pid: pid_t, sleep: @escaping (TimeInterval) -> Void) -> () -> String? {
        var cachedApp: AXUIElement?
        var enabled = false
        return {
            let app = cachedApp ?? {
                let created = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(created, 0.25)
                cachedApp = created
                return created
            }()
            func read() -> (AXError, String?) {
                var focused: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
                guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (status, nil) }
                let element = focused as! AXUIElement // swiftlint:disable:this force_cast
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role) == .success,
                   role as? String == kAXSecureTextFieldSubrole as String { return (.success, nil) }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return (.success, nil) }
                return (.success, value as? String)
            }
            var (status, value) = read()
            if value == nil, !enabled, status == .noValue || status == .cannotComplete {
                enabled = true
                if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                    for _ in 0 ..< 4 where value == nil {
                        sleep(0.1)
                        (status, value) = read()
                    }
                }
            }
            return value
        }
    }
}
