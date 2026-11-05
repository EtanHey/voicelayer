import Foundation

// Settings › Speech: the view side of the V10 clone-engine contract (docs/clone-engine/README.md).
//
// AIDEV-NOTE: VoiceBar owns the engine lifecycle (V10). Nothing here supervises, launches, signals or parses socket
// frames. The app feeds `VoiceState.cloneEngine` snapshots and `clone_engine` acknowledgements in, and sends
// `CloneEngineCommand.wireObject` through `VoiceState.sendCommand`. An acknowledgement only means VoiceBar accepted
// the request; what the row shows always comes from the latest lifecycle snapshot.

/// `reason` in the `clone_engine` event. V10 appends a status to some codes (`engine_exited(1)`), so only the part
/// before `(` is matched. A code this build doesn't know is kept, not guessed.
public enum CloneEngineReason: Equatable, Sendable {
    case adoptedExisting, portOccupied, pythonMissing, scriptMissing, scriptUnresolved
    case launchFailed, exitedEarly, engineExited, startupTimeout, healthUnavailable, stopTimeout
    case userStop, voicebarQuit
    case unrecognized(String)

    public init(code: String) {
        let base = code.split(separator: "(", maxSplits: 1).first.map(String.init) ?? code
        switch base {
        case "adopted_existing": self = .adoptedExisting
        case "port_occupied": self = .portOccupied
        case "python_missing": self = .pythonMissing
        case "script_missing": self = .scriptMissing
        case "script_unresolved": self = .scriptUnresolved
        case "launch_failed": self = .launchFailed
        case "exited_early": self = .exitedEarly
        case "engine_exited": self = .engineExited
        case "startup_timeout": self = .startupTimeout
        case "health_unavailable": self = .healthUnavailable
        case "stop_timeout": self = .stopTimeout
        case "user_stop": self = .userStop
        case "voicebar_quit": self = .voicebarQuit
        default: self = .unrecognized(code)
        }
    }
}

extension CloneEngineSnapshot {
    var parsedReason: CloneEngineReason? { reason.map(CloneEngineReason.init(code:)) }
    var sinceDate: Date? { ISO8601DateFormatter().date(from: since) }
}

public enum CloneEngineAction: Equatable, Sendable {
    case start, restart, stop
    case setAutostart(Bool)
}

/// `{"cmd":"clone_engine","action":…,"id":…}`; only `set_autostart` carries a JSON boolean `value`.
public struct CloneEngineCommand: Equatable, Sendable {
    public let action: CloneEngineAction
    public let id: String

    public var wireObject: [String: Any] {
        var object: [String: Any] = ["cmd": "clone_engine", "id": id]
        switch action {
        case .start: object["action"] = "start"
        case .restart: object["action"] = "restart"
        case .stop: object["action"] = "stop"
        case .setAutostart(let value): object["action"] = "set_autostart"; object["value"] = value
        }
        return object
    }
}

/// Why a request didn't go through: V10's stable reject reasons, plus this side's own outcomes.
public enum CloneEngineRefusal: Equatable, Sendable {
    case foreignEngine, invalidCommand, quitting, isolatedApp
    case unrecognized(String?)
    /// No acknowledgement arrived in time (for example a VoiceBar without V10).
    case noReply
    /// VoiceBar isn't connected, so nothing was sent.
    case notSent

    init(rejectReason: String?) {
        switch rejectReason {
        case "foreign_engine": self = .foreignEngine
        case "invalid_command": self = .invalidCommand
        case "quitting": self = .quitting
        case "isolated_app": self = .isolatedApp
        default: self = .unrecognized(rejectReason)
        }
    }

    var message: String {
        switch self {
        case .foreignEngine: "VoiceBar didn't start this engine, so it won't stop or restart it."
        case .invalidCommand: "VoiceBar didn't recognize that request. It may need an update."
        case .quitting: "VoiceBar is quitting, so it left the engine as it was."
        case .isolatedApp: "Only the installed VoiceBar can control the voice engine. This copy can't."
        case .unrecognized(let code?): "VoiceBar refused the request (\(code))."
        case .unrecognized(nil): "VoiceBar refused the request and didn't say why."
        case .noReply: "VoiceBar didn't confirm the request, so nothing changed here. It may need an update."
        case .notSent: "VoiceBar isn't connected, so the request wasn't sent."
        }
    }
}

public enum CloneEngineButton: String, Hashable, Sendable {
    case start = "Start engine", restart = "Restart", stop = "Stop", tryAgain = "Try again"
    public var title: String { rawValue }
}


/// The pure state machine behind the engine row. Tests drive it without a socket, a clock or a view.
public struct CloneEngineControlModel: Equatable {
    /// How long a request waits for its acknowledgement, and how long an accepted Start/Restart waits for a
    /// lifecycle change before the row says nothing changed.
    public static let replyWindow: TimeInterval = 5

    struct Request: Equatable {
        let command: CloneEngineCommand
        let at: Date
    }

    public private(set) var snapshot: CloneEngineSnapshot?
    private(set) var inFlight: Request?
    /// An accepted lifecycle request still waiting for its first lifecycle change.
    private(set) var accepted: Request?
    /// V10 publishes only on a change, so an accepted retry that lands in the same state produces no event.
    private(set) var acceptedWithoutChange = false
    private(set) var refusal: CloneEngineRefusal?
    /// A `foreign_engine` rejection for this PID, even if the snapshot didn't say `adopted_existing`.
    private(set) var foreignPID: Int?
    private(set) var pendingAutostart: Bool?

    public init(snapshot: CloneEngineSnapshot? = nil) { self.snapshot = snapshot }

    var isForeign: Bool {
        guard let snapshot else { return false }
        return snapshot.parsedReason == .adoptedExisting || (foreignPID != nil && foreignPID == snapshot.pid)
    }

    /// An owned process VoiceBar still holds after a failure (`health_unavailable`, `stop_timeout`): it can be
    /// stopped or restarted.
    private var holdsOwnedProcess: Bool { snapshot?.state == .failed && snapshot?.pid != nil && !isForeign }

    public mutating func receive(snapshot new: CloneEngineSnapshot?) {
        let old = snapshot
        snapshot = new
        guard let new else {
            accepted = nil
            acceptedWithoutChange = false
            pendingAutostart = nil
            return
        }
        if old?.state != new.state || old?.since != new.since || old?.pid != new.pid || old?.reason != new.reason {
            accepted = nil
            acceptedWithoutChange = false
            if refusal == .foreignEngine { refusal = nil }
        }
        if foreignPID != new.pid { foreignPID = nil }
        if pendingAutostart == new.startWithVoiceBar { pendingAutostart = nil }
    }

    /// Which buttons the current state offers. Starting/Restarting offer none (spec: disabled while it loads).
    func buttons() -> [CloneEngineButton] {
        switch snapshot?.state {
        case nil, .starting?, .restarting?: []
        case .running?: [.restart, .stop]
        case .stopped?: [.start]
        case .failed?: holdsOwnedProcess ? [.tryAgain, .stop] : [.tryAgain]
        }
    }

    func isEnabled(_ button: CloneEngineButton) -> Bool {
        guard inFlight == nil, buttons().contains(button) else { return false }
        return button == .restart || button == .stop ? !isForeign : true
    }

    /// Try again restarts an owned process VoiceBar still holds; otherwise it is Start (which may adopt).
    func action(for button: CloneEngineButton) -> CloneEngineAction {
        switch button {
        case .start: .start
        case .restart: .restart
        case .stop: .stop
        case .tryAgain: holdsOwnedProcess ? .restart : .start
        }
    }

    /// The command to send for a button press, or nil when the button isn't available now.
    public mutating func press(_ button: CloneEngineButton, id: String, now: Date) -> CloneEngineCommand? {
        guard isEnabled(button) else { return nil }
        return begin(action(for: button), id: id, now: now)
    }

    /// The command for a "Start with VoiceBar" change. It affects the next app opening only (V10).
    public mutating func setStartWithVoiceBar(_ value: Bool, id: String, now: Date) -> CloneEngineCommand? {
        guard let snapshot, inFlight == nil, value != (pendingAutostart ?? snapshot.startWithVoiceBar) else {
            return nil
        }
        pendingAutostart = value
        return begin(.setAutostart(value), id: id, now: now)
    }

    private mutating func begin(_ action: CloneEngineAction, id: String, now: Date) -> CloneEngineCommand {
        let command = CloneEngineCommand(action: action, id: id)
        inFlight = Request(command: command, at: now)
        refusal = nil
        accepted = nil
        acceptedWithoutChange = false
        return command
    }

    public mutating func sendFailed(id: String) {
        guard inFlight?.command.id == id else { return }
        fail(.notSent)
    }

    public mutating func receive(ackID id: String, accepted isAccepted: Bool, reason: String?, now: Date) {
        guard let request = inFlight, request.command.id == id else { return }
        guard isAccepted else {
            let refusal = CloneEngineRefusal(rejectReason: reason)
            if refusal == .foreignEngine { foreignPID = snapshot?.pid }
            fail(refusal)
            return
        }
        inFlight = nil
        if case .setAutostart = request.command.action { return }
        accepted = Request(command: request.command, at: now)
    }

    /// Ends a request that never got an acknowledgement, and an accepted one that never changed the state.
    public mutating func expire(now: Date) {
        if let inFlight, now.timeIntervalSince(inFlight.at) >= Self.replyWindow { fail(.noReply) }
        if let accepted, now.timeIntervalSince(accepted.at) >= Self.replyWindow { acceptedWithoutChange = true }
    }

    /// When `expire(now:)` next has something to do.
    var nextDeadline: Date? {
        if let inFlight { return inFlight.at.addingTimeInterval(Self.replyWindow) }
        if let accepted, !acceptedWithoutChange { return accepted.at.addingTimeInterval(Self.replyWindow) }
        return nil
    }

    private mutating func fail(_ reason: CloneEngineRefusal) {
        if case .setAutostart? = inFlight?.command.action { pendingAutostart = nil }
        inFlight = nil
        accepted = nil
        acceptedWithoutChange = false
        refusal = reason
    }
}
