import Foundation

/// Logging seam for the CGEventTap hotkey path.
///
/// AIDEV-NOTE: The tap is installed at the session level, so it sees EVERY key
/// event on the machine — passwords included. Anything logged before the hotkey
/// match check is therefore a keystroke log, and `com.voicelayer.voicebar` routes
/// stderr to a file, so those lines land on disk. That is exactly what happened
/// between 7e3f0a5 (2026-03-30) and this fix (2026-09-06): 634 KB of everything
/// Etan typed, in a world-readable file.
///
/// The rule for callers in the tap path:
///
/// - `log(_:)` is for MATCHED hotkeys only (keycodes 79/96, mouse buttons 3/4/5)
///   and for tap lifecycle transitions. It can never carry a keystroke the user
///   did not deliberately aim at VoiceBar, so it is always emitted.
/// - `verbose(_:)` is for per-event tracing that sees every keystroke. It is OFF
///   unless someone explicitly turns it on, and it must never default to on.
///
/// Nothing in the tap path should call `NSLog` directly — that bypasses the gate
/// and is how the original bug shipped.
enum HotkeyDiagnostics {
    /// UserDefaults key for the opt-in per-event trace. Absent reads as `false`.
    ///
    /// Turning this on produces a keystroke log by design. It exists for
    /// debugging a dead hotkey on a machine you own; leave it off otherwise.
    ///
    /// Read once, when the tap starts — so writing it while VoiceBar is running
    /// changes nothing until the next launch, and neither does writing it back
    /// to false. Restart VoiceBar after either change.
    static let verboseLoggingDefaultsKey = "VoiceBarVerboseHotkeyLogging"

    /// Where both levels write. Replaced in tests; `NSLog` in production.
    static var sink: (String) -> Void = { NSLog("%@", $0) }

    /// Per-event tracing switch. MUST default to `false` — see the type doc.
    static var isVerboseEnabled = false

    /// Read the opt-in switch. Called once when the event tap starts.
    static func loadVerboseSetting(defaults: UserDefaults = VoiceBarDefaults.make()) {
        isVerboseEnabled = defaults.bool(forKey: verboseLoggingDefaultsKey)
    }

    /// Log a matched-hotkey or tap-lifecycle event. Always emitted.
    static func log(_ message: @autoclosure () -> String) {
        sink(message())
    }

    /// Log a per-event trace line. Emitted only when explicitly enabled.
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        sink(message())
    }
}
