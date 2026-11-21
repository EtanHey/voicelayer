import ApplicationServices
import Foundation
import VoiceBarUI

/// Dictation's half of the unreadable-focus recovery that Option+F5 already has.
///
/// A Chromium/Electron app can answer the focus query with kAXErrorNoValue or kAXErrorCannotComplete
/// while its accessibility tree is off. Then the ready-time paste target cannot be verified, and the
/// transcript stays in History (M4, 18 Nov: every auto-paste into a relaunched T3 Code). This asks the
/// frontmost Chromium-family app for its tree with `SelectionFocusAX.enableManualAccessibility`, the
/// one implementation both paths share. It never reads text, never pastes and never decides admission:
/// the ready-time capture runs again afterwards with every existing rule (same app, same element and
/// window, writable text, never secure or protected).
///
/// Everything here runs on `run` (off the main thread in production). Recording never waits for it.
struct DictationFocusRecovery {
    enum Outcome: String {
        case readable
        case recovered
        case untrusted = "ax_untrusted"
        case noFrontmostApp = "no_frontmost_app"
        case notChromiumFamily = "not_chromium_family"
        case notRecoverable = "focus_error_not_recoverable"
        case enableFailed = "manual_ax_set_failed"
        case stillUnreadable = "still_unreadable"
    }

    /// Re-queries after the set: 20 × 0.1 s. The three Option+F5 recoveries in the M4 log (Oct 21, Nov 1,
    /// Nov 2) were all still -25212 after 8 × 0.1 s, so dictation, which waits off the main thread, waits longer.
    static let retryLimit = 20
    static let retryStep: TimeInterval = 0.1

    var ax: SelectionFocusAX
    /// Runs the recovery. Production: a serial utility queue.
    var run: (@escaping () -> Void) -> Void
    /// Brings the ready-time answer back. Production: the main queue.
    var deliver: (@escaping () -> Void) -> Void
    var log: (String, [String: String]) -> Void = { CommandModeAXHelper.logNativePaste($0, $1) }

    private static let queue = DispatchQueue(label: "com.voicelayer.dictation-focus-recovery", qos: .userInitiated)

    static let live = DictationFocusRecovery(ax: .live,
                                             run: { queue.async(execute: $0) },
                                             deliver: { DispatchQueue.main.async(execute: $0) })

    /// One attempt: readable focus is left alone; an unreadable focus in a Chromium-family app gets
    /// AXManualAccessibility and bounded re-queries; any other app is never touched.
    func recover(phase: String) -> Outcome {
        var fields = ["phase": phase, "manual_ax_attempted": "false"]
        func done(_ outcome: Outcome) -> Outcome {
            fields["outcome"] = outcome.rawValue
            log("paste_native_focus_recovery", fields)
            return outcome
        }
        guard ax.trusted() else { return done(.untrusted) }
        let (status, focus) = ax.queryFocus()
        fields["ax_status"] = String((focus?.queryStatus ?? status).rawValue)
        if status == .success { return done(.readable) }
        guard SelectionFocusAX.isUnreadable(status) else { return done(.notRecoverable) }
        guard let app = ax.frontmostApp() else { return done(.noFrontmostApp) }
        fields["pid"] = String(app.pid)
        guard ax.isChromiumFamily(app) else { return done(.notChromiumFamily) }
        fields["manual_ax_attempted"] = "true"
        let recovery = ax.enableManualAccessibility(on: app, status: status, focus: focus,
                                                    retryLimit: Self.retryLimit, step: Self.retryStep)
        fields["manual_ax_status"] = String(recovery.enableStatus.rawValue)
        fields["retries"] = String(recovery.retries)
        fields["retry_statuses"] = recovery.retryStatuses.joined(separator: ",")
        guard recovery.enableStatus == .success else { return done(.enableFailed) }
        return done(recovery.status == .success ? .recovered : .stillUnreadable)
    }

    /// Wires both moments into the dictation path.
    /// - Record start (F5 key-down): fire and forget, so the tree is usually on before the transcript is.
    /// - Ready time: only after the ready-time capture found no target; the capture then runs again.
    func install(on state: VoiceState) {
        state.dictationFocusRecoveryKick = { run { _ = recover(phase: "record_start") } }
        state.readyFocusRecovery = { completion in
            run {
                _ = recover(phase: "ready")
                deliver(completion)
            }
        }
    }
}
