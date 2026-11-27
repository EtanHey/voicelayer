import VoiceBarUI

/// The F5 listener as the lifecycle sees it: `HotkeyManager` in the app, a fake in tests (no real event tap).
protocol HotkeyListening: AnyObject {
    /// Creates and enables the tap; false when a permission is missing or the tap can't be created.
    func start() -> Bool
    /// Disables and removes the tap. Safe on a listener that never started.
    func stop()
    var missingPermissions: [HotkeyPermission] { get }
    var isEnabled: Bool { get }
    /// Disables and removes the tap, then calls `teardown` on main once it can no longer consume an event.
    func stop(teardown: @escaping () -> Void)
}

extension HotkeyListening {
    /// Listeners whose `stop()` is synchronous are torn down when it returns.
    func stop(teardown: @escaping () -> Void) {
        stop()
        teardown()
    }
}

extension HotkeyManager: HotkeyListening {
    var missingPermissions: [HotkeyPermission] {
        permissionStatus.missingPermissions
    }

    func stop(teardown: @escaping () -> Void) {
        stopTap(teardown: teardown)
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
        running?.isEnabled == true
    }

    /// At launch. A listener that fails to start is stopped before it is dropped, so no half-made tap survives.
    func start() -> HotkeyListenerRestartOutcome {
        if running?.isEnabled == true { return .alreadyRunning }
        stop()
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
        if running?.isEnabled == true { return .alreadyRunning }
        if isRecording { return .refusedWhileRecording }
        stop() // Rebuild a disabled tap, never leave it behind as a second consumer.
        return start()
    }

    /// L105: a changed dictation key or mouse role. The tap is rebuilt from the new binding. The new tap is armed only
    /// after the old one's teardown has finished on its own thread (Codex r1 on #980), so the two never consume at the
    /// same time. Refused while a recording is in progress so a held or locked take never loses the key that ends it.
    /// `completion` runs on main.
    func rebind(isRecording: Bool, completion: @escaping (HotkeyListenerRestartOutcome) -> Void) {
        if isRecording { completion(.refusedWhileRecording); return }
        guard let old = running else { completion(start()); return }
        running = nil
        old.stop(teardown: { [weak self] in
            guard let self else { return }
            completion(self.start())
        })
    }

    func stop() {
        running?.stop()
        running = nil
    }
}
