import VoiceBarUI

/// The F5 listener as the lifecycle sees it: `HotkeyManager` in the app, a fake in tests (no real event tap).
protocol HotkeyListening: AnyObject {
    /// Creates and enables the tap; false when a permission is missing or the tap can't be created.
    func start() -> Bool
    /// Disables and removes the tap. Safe on a listener that never started.
    func stop()
    var missingPermissions: [HotkeyPermission] { get }
}

extension HotkeyManager: HotkeyListening {
    var missingPermissions: [HotkeyPermission] {
        permissionStatus.missingPermissions
    }
}

/// Starts the F5 listener at launch and again on "Restart F5 listener". Only the start/stop lifecycle lives here:
/// the listener's key handling, gestures, relay and capture are the manager's and are not touched.
final class HotkeyListenerLifecycle {
    private let makeListener: () -> HotkeyListening
    private var running: HotkeyListening?

    init(makeListener: @escaping () -> HotkeyListening) {
        self.makeListener = makeListener
    }

    var isRunning: Bool {
        running != nil
    }

    /// At launch. A listener that fails to start is stopped before it is dropped, so no half-made tap survives.
    func start() -> HotkeyListenerRestartOutcome {
        if running != nil { return .alreadyRunning }
        let listener = makeListener()
        guard listener.start() else {
            listener.stop()
            return .failed(missing: listener.missingPermissions)
        }
        running = listener
        return .started
    }

    /// "Restart F5 listener": a running listener is left alone (never a second tap), and nothing starts while a
    /// recording is in progress.
    func restart(isRecording: Bool) -> HotkeyListenerRestartOutcome {
        if running != nil { return .alreadyRunning }
        if isRecording { return .refusedWhileRecording }
        return start()
    }

    func stop() {
        running?.stop()
        running = nil
    }
}
