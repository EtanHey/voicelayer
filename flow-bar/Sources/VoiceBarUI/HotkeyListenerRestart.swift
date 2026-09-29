import SwiftUI

/// What "Restart F5 listener" did. The listener is the event tap that starts at launch; permissions granted later
/// need it started again.
public enum HotkeyListenerRestartOutcome: Equatable, Sendable {
    case started
    case alreadyRunning
    case refusedWhileRecording
    case failed(missing: [HotkeyPermission])
}

/// The result line under the button, in Settings and in the wizard's F5 key step.
public struct HotkeyListenerRestartLine: Equatable, Sendable {
    public let text: String
    public let succeeded: Bool

    /// Settings and the wizard offer the restart only while the listener is off (never started, or failed).
    public static func showsRestart(listenerActive: Bool) -> Bool {
        !listenerActive
    }

    /// macOS can keep reporting a just-granted permission as missing to a running app; a relaunch always picks it up.
    static let relaunchHint = "If you just allowed access, quit and reopen VoiceBar."

    public init(text: String, succeeded: Bool) {
        self.text = text
        self.succeeded = succeeded
    }

    public init(outcome: HotkeyListenerRestartOutcome) {
        switch outcome {
        case .started:
            self.init(text: "F5 listener is on.", succeeded: true)
        case .alreadyRunning:
            self.init(text: "F5 listener is already on.", succeeded: true)
        case .refusedWhileRecording:
            self.init(text: "Not restarted: a recording is in progress. Try again when it ends.", succeeded: false)
        case let .failed(missing) where missing.isEmpty:
            self.init(
                text: "Still off: the F5 listener couldn't start. \(Self.relaunchHint)",
                succeeded: false
            )
        case let .failed(missing):
            let names = missing.map(\.label)
            self.init(
                text: "Still off: \(names.joined(separator: " and ")) \(names.count == 1 ? "is" : "are") missing. \(Self.relaunchHint)",
                succeeded: false
            )
        }
    }
}

/// The restart result, in place under the button.
struct HotkeyListenerRestartLineView: View {
    let line: HotkeyListenerRestartLine

    var body: some View {
        Label {
            Text(line.text)
                .foregroundStyle(line.succeeded ? Color.primary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: line.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(line.succeeded ? Color.green : Color.red)
        }
        .font(.callout)
    }
}
