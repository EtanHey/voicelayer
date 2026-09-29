import Foundation

/// What "Restart F5 listener" did. The listener is the event tap that starts at launch; permissions granted later
/// need it started again.
public enum HotkeyListenerRestartOutcome: Equatable, Sendable {
    case started
    case alreadyRunning
    case refusedWhileRecording
    case failed(missing: [HotkeyPermission])
}
