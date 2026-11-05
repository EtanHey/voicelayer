import Foundation
import Observation

// Settings › Speech: the view side of the V10 clone-engine contract ("Clone engine control (V10 → U3)").
//
// AIDEV-NOTE: VoiceBar owns the engine lifecycle (V10). Nothing in this file supervises, launches, signals,
// parses socket frames or imports runtime code. The integration adapter maps V10's `VoiceState.cloneEngine`
// (`CloneEngineSnapshot`, a V10 type this file deliberately does not name) into `CloneEngineStatus`, routes `clone_engine` acknowledgements into `receive(ack:)`, and hands
// `CloneEngineCommand.wireObject` to `VoiceState.sendCommand`. An acknowledgement only means VoiceBar accepted
// the request; what the row shows always comes from the next lifecycle snapshot.

/// `state` in the `clone_engine` event.
public enum CloneEngineLifecycle: String, Equatable, Sendable, CaseIterable {
    case running, starting, restarting, stopped, failed
}

/// `reason` in the `clone_engine` event: a nullable stable code. A code this build doesn't know is kept, not guessed.
public enum CloneEngineReason: Equatable, Sendable {
    case adoptedExisting, portOccupied, launchFailed, engineExited, startupTimeout, healthUnavailable
    case userStop, voicebarQuit
    case unrecognized(String)

    public init(code: String) {
        switch code {
        case "adopted_existing": self = .adoptedExisting
        case "port_occupied": self = .portOccupied
        case "launch_failed": self = .launchFailed
        case "engine_exited": self = .engineExited
        case "startup_timeout": self = .startupTimeout
        case "health_unavailable": self = .healthUnavailable
        case "user_stop": self = .userStop
        case "voicebar_quit": self = .voicebarQuit
        default: self = .unrecognized(code)
        }
    }
}

/// One `clone_engine` lifecycle event. `nil` where Settings holds no snapshot means "not reported", never "stopped".
public struct CloneEngineStatus: Equatable, Sendable {
    public var state: CloneEngineLifecycle
    public var since: Date?
    public var reason: CloneEngineReason?
    public var pid: Int?
    public var startWithVoiceBar: Bool

    public init(state: CloneEngineLifecycle, since: Date?, reason: CloneEngineReason?, pid: Int?,
                startWithVoiceBar: Bool) {
        self.state = state
        self.since = since
        self.reason = reason
        self.pid = pid.flatMap { $0 > 0 ? $0 : nil }
        self.startWithVoiceBar = startWithVoiceBar
    }

    /// From the raw V10 fields, so integration maps `VoiceState.cloneEngine` (V10's `CloneEngineSnapshot`) in one
    /// line: `CloneEngineStatus(state: s.state.rawValue, since: s.since, reason: s.reason, pid: s.pid,
    /// startWithVoiceBar: s.startWithVoiceBar)`. An unknown state is nil (unavailable); an unreadable `since` is
    /// kept as unknown rather than replaced with a guess.
    public init?(state: String, since: String?, reason: String?, pid: Int?, startWithVoiceBar: Bool) {
        guard let lifecycle = CloneEngineLifecycle(rawValue: state) else { return nil }
        self.init(state: lifecycle, since: since.flatMap { ISO8601DateFormatter().date(from: $0) },
                  reason: reason.map(CloneEngineReason.init(code:)), pid: pid, startWithVoiceBar: startWithVoiceBar)
    }

    /// An adopted engine stays foreign: VoiceBar may not stop or restart it (V10).
    public var isForeign: Bool { reason == .adoptedExisting }
}

public enum CloneEngineAction: Equatable, Sendable {
    case start, restart, stop
    case setAutostart(Bool)

    var wireAction: String {
        switch self {
        case .start: "start"
        case .restart: "restart"
        case .stop: "stop"
        case .setAutostart: "set_autostart"
        }
    }
}

/// `{"cmd":"clone_engine","action":…,"id":…}`; only `set_autostart` carries a JSON boolean `value`.
public struct CloneEngineCommand: Equatable, Sendable {
    public let action: CloneEngineAction
    public let id: String

    public var wireObject: [String: Any] {
        var object: [String: Any] = ["cmd": "clone_engine", "action": action.wireAction, "id": id]
        if case .setAutostart(let value) = action { object["value"] = value }
        return object
    }
}

/// A `clone_engine` acknowledgement (`outcome: accept | reject`), matched to its command by `id`.
public struct CloneEngineAck: Equatable, Sendable {
    public let id: String
    public let accepted: Bool
    public let reason: String?

    public init(id: String, accepted: Bool, reason: String? = nil) {
        self.id = id
        self.accepted = accepted
        self.reason = reason
    }
}

/// Why a request didn't go through. Rejections carry V10's stable reason; the rest are this side's own outcomes.
public enum CloneEngineRefusal: Equatable, Sendable {
    case foreignEngine, invalidCommand, quitting, isolatedApp
    case unrecognized(String?)
    /// No acknowledgement arrived in time (for example a VoiceBar without V10).
    case noReply
    /// The adapter couldn't send it (not connected).
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

public enum CloneEngineButton: Hashable, Sendable {
    case start, restart, stop, tryAgain

    public var title: String {
        switch self {
        case .start: "Start engine"
        case .restart: "Restart"
        case .stop: "Stop"
        case .tryAgain: "Try again"
        }
    }
}

public enum CloneEnginePillTone: Equatable, Sendable {
    case green, blue, grey, red
}

/// Everything the engine row renders, derived from the last snapshot plus any request in flight.
public struct CloneEnginePresentation: Equatable {
    public struct Action: Equatable {
        public let button: CloneEngineButton
        public let isEnabled: Bool
    }

    public let pill: String
    public let tone: CloneEnginePillTone
    public let pulses: Bool
    public let showsProgress: Bool
    public let description: String
    public let actions: [Action]
    /// A line under the description: the outcome of the last request, or that one is waiting.
    public let note: String?
    public let noteIsProblem: Bool
    /// `nil` = unavailable (no snapshot); otherwise what the toggle shows, including a pending change.
    public let startWithVoiceBar: Bool?
    public let startWithVoiceBarEnabled: Bool

    /// Status pills read as text (spec accessibility rule).
    public var accessibilityStatus: String { "Clone engine: \(pill.lowercased())" }
}

/// The pure state machine behind the engine row. Tests drive it without a socket, a clock or a view.
public struct CloneEngineControlModel: Equatable {
    public static let ackTimeout: TimeInterval = 5

    struct InFlight: Equatable {
        let command: CloneEngineCommand
        let sentAt: Date
    }

    public private(set) var snapshot: CloneEngineStatus?
    private(set) var inFlight: InFlight?
    /// Accepted lifecycle request still waiting for its first lifecycle change.
    private(set) var accepted: CloneEngineAction?
    private(set) var refusal: CloneEngineRefusal?
    /// A `foreign_engine` rejection for this PID, even if the snapshot didn't say `adopted_existing`.
    private(set) var foreignPID: Int?
    private(set) var pendingAutostart: Bool?

    public init(snapshot: CloneEngineStatus? = nil) {
        self.snapshot = snapshot
    }

    private var isForeign: Bool {
        guard let snapshot else { return false }
        return snapshot.isForeign || (foreignPID != nil && foreignPID == snapshot.pid)
    }

    public mutating func receive(snapshot new: CloneEngineStatus?) {
        let old = snapshot
        snapshot = new
        guard let new else {
            accepted = nil
            pendingAutostart = nil
            return
        }
        if old?.state != new.state || old?.since != new.since || old?.pid != new.pid || old?.reason != new.reason {
            accepted = nil
            if case .foreignEngine? = refusal { refusal = nil }
        }
        if foreignPID != new.pid { foreignPID = nil }
        if pendingAutostart == new.startWithVoiceBar { pendingAutostart = nil }
    }

    /// Which buttons the current state offers. Starting/Restarting offer none (spec: disabled while it loads).
    func buttons() -> [CloneEngineButton] {
        guard let snapshot else { return [] }
        switch snapshot.state {
        case .running: return [.restart, .stop]
        case .starting, .restarting: return []
        case .stopped: return [.start]
        case .failed:
            // A missed health poll keeps the owned process alive (V10); it can still be stopped.
            return snapshot.reason == .healthUnavailable && snapshot.pid != nil ? [.tryAgain, .stop] : [.tryAgain]
        }
    }

    func isEnabled(_ button: CloneEngineButton) -> Bool {
        guard inFlight == nil, buttons().contains(button) else { return false }
        switch button {
        case .restart, .stop: return !isForeign
        case .start, .tryAgain: return true
        }
    }

    func action(for button: CloneEngineButton) -> CloneEngineAction {
        switch button {
        case .start: return .start
        case .restart: return .restart
        case .stop: return .stop
        case .tryAgain:
            // An owned engine that stopped answering is restarted; otherwise Start (which may adopt a foreign one).
            return snapshot?.reason == .healthUnavailable && snapshot?.pid != nil && !isForeign ? .restart : .start
        }
    }

    /// The command to send for a button press, or nil when the button isn't available now.
    public mutating func press(_ button: CloneEngineButton, id: String, now: Date) -> CloneEngineCommand? {
        guard isEnabled(button) else { return nil }
        return begin(action(for: button), id: id, now: now)
    }

    /// The command for a "Start with VoiceBar" change. It affects the next app opening only (V10).
    public mutating func setStartWithVoiceBar(_ value: Bool, id: String, now: Date) -> CloneEngineCommand? {
        guard snapshot != nil, inFlight == nil else { return nil }
        guard value != (pendingAutostart ?? snapshot?.startWithVoiceBar) else { return nil }
        pendingAutostart = value
        return begin(.setAutostart(value), id: id, now: now)
    }

    private mutating func begin(_ action: CloneEngineAction, id: String, now: Date) -> CloneEngineCommand {
        let command = CloneEngineCommand(action: action, id: id)
        inFlight = InFlight(command: command, sentAt: now)
        refusal = nil
        accepted = nil
        return command
    }

    /// The adapter couldn't send the command at all.
    public mutating func sendFailed(id: String) {
        guard inFlight?.command.id == id else { return }
        fail(.notSent)
    }

    public mutating func receive(ack: CloneEngineAck) {
        guard let inFlight, inFlight.command.id == ack.id else { return }
        if ack.accepted {
            self.inFlight = nil
            if case .setAutostart = inFlight.command.action { return }
            accepted = inFlight.command.action
            return
        }
        let reason = CloneEngineRefusal(rejectReason: ack.reason)
        if reason == .foreignEngine { foreignPID = snapshot?.pid }
        fail(reason)
    }

    /// Ends a request that never got an acknowledgement.
    public mutating func expireUnanswered(now: Date) {
        guard let inFlight, now.timeIntervalSince(inFlight.sentAt) >= Self.ackTimeout else { return }
        fail(.noReply)
    }

    var ackDeadline: Date? { inFlight.map { $0.sentAt.addingTimeInterval(Self.ackTimeout) } }

    private mutating func fail(_ reason: CloneEngineRefusal) {
        if case .setAutostart? = inFlight?.command.action { pendingAutostart = nil }
        inFlight = nil
        accepted = nil
        refusal = reason
    }

    public func presentation(now: Date, timeZone: TimeZone = .current,
                             locale: Locale = .current) -> CloneEnginePresentation {
        let actions = buttons().map { CloneEnginePresentation.Action(button: $0, isEnabled: isEnabled($0)) }
        let note: String?
        let noteIsProblem: Bool
        if let refusal {
            note = refusal.message
            noteIsProblem = true
        } else if let inFlight {
            note = Self.sendingNote(inFlight.command.action)
            noteIsProblem = false
        } else if let accepted {
            note = Self.acceptedNote(accepted)
            noteIsProblem = false
        } else if isForeign, snapshot?.state == .running {
            note = CloneEngineRefusal.foreignEngine.message
            noteIsProblem = false
        } else {
            note = nil
            noteIsProblem = false
        }
        guard let snapshot else {
            return CloneEnginePresentation(
                pill: "Unavailable", tone: .grey, pulses: false, showsProgress: false,
                description: "VoiceBar hasn't reported the voice engine's status, so Settings can't control it yet.",
                actions: [], note: note, noteIsProblem: noteIsProblem,
                startWithVoiceBar: nil, startWithVoiceBarEnabled: false
            )
        }
        let (pill, tone, pulses, progress) = Self.pill(snapshot.state)
        return CloneEnginePresentation(
            pill: pill, tone: tone, pulses: pulses, showsProgress: progress,
            description: Self.description(snapshot, now: now, timeZone: timeZone, locale: locale),
            actions: actions, note: note, noteIsProblem: noteIsProblem,
            startWithVoiceBar: pendingAutostart ?? snapshot.startWithVoiceBar,
            startWithVoiceBarEnabled: inFlight == nil
        )
    }

    static func pill(_ state: CloneEngineLifecycle) -> (String, CloneEnginePillTone, Bool, Bool) {
        switch state {
        case .running: ("Running", .green, false, false)
        case .starting: ("Starting", .blue, true, true)
        case .restarting: ("Restarting", .blue, false, true)
        case .stopped: ("Stopped", .grey, false, false)
        case .failed: ("Couldn't start", .red, false, false)
        }
    }

    static func description(_ snapshot: CloneEngineStatus, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        switch snapshot.state {
        case .running:
            // `running` means the health endpoint answers; it says nothing about how fast the first sound is.
            guard let since = snapshot.since else { return "Ready." }
            return "Ready since \(sinceLabel(since, now: now, timeZone: timeZone, locale: locale))."
        case .starting:
            // V10's startup deadline is 120 seconds before the first healthy answer.
            return "Loading your voice model. This can take up to two minutes."
        case .restarting:
            switch snapshot.reason {
            case .engineExited: return "It stopped unexpectedly, so VoiceBar is starting it again."
            case .healthUnavailable: return "It stopped answering, so VoiceBar is starting it again."
            case .startupTimeout: return "It took too long to start, so VoiceBar is trying again."
            case .launchFailed: return "It couldn't launch, so VoiceBar is trying again."
            default: return "VoiceBar is starting it again."
            }
        case .stopped:
            return "Long replies use the fast voice until it runs."
        case .failed:
            switch snapshot.reason {
            case .portOccupied:
                return "Another program is using the voice engine's port, so VoiceBar can't start its own."
            case .launchFailed:
                return "VoiceBar couldn't launch the voice engine. Its Python runtime may be missing."
            case .startupTimeout:
                return "The voice engine didn't answer within two minutes of starting."
            case .healthUnavailable:
                return "The voice engine stopped answering. It's still running, so a reply in progress can finish."
            case .engineExited:
                return "The voice engine quit unexpectedly."
            case .unrecognized(let code):
                return "The voice engine couldn't start. VoiceBar reported \u{201C}\(code)\u{201D}."
            case .adoptedExisting, .userStop, .voicebarQuit, nil:
                return "The voice engine couldn't start, and VoiceBar didn't say why."
            }
        }
    }

    static func sinceLabel(_ since: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(since, inSameDayAs: now) ? "jjmm" : "djjmmMMM")
        return formatter.string(from: since)
    }

    static func sendingNote(_ action: CloneEngineAction) -> String {
        switch action {
        case .start: "Asking VoiceBar to start the engine…"
        case .restart: "Asking VoiceBar to restart the engine…"
        case .stop: "Asking VoiceBar to stop the engine…"
        case .setAutostart: "Saving…"
        }
    }

    static func acceptedNote(_ action: CloneEngineAction) -> String? {
        switch action {
        case .start: "VoiceBar is starting the engine. The status above updates as it reports in."
        case .restart: "VoiceBar is restarting the engine. The status above updates as it reports in."
        case .stop: "VoiceBar is stopping the engine."
        case .setAutostart: nil
        }
    }
}

/// The injectable view model the Speech pane observes. Integration feeds it V10 snapshots and acknowledgements and
/// gives it a sender; tests give it fakes.
@Observable
public final class CloneEngineControlViewModel {
    public private(set) var model: CloneEngineControlModel
    private let send: (CloneEngineCommand) -> Bool
    private let makeID: () -> String
    private let now: () -> Date

    public init(
        snapshot: CloneEngineStatus? = nil,
        send: @escaping (CloneEngineCommand) -> Bool,
        makeID: @escaping () -> String = { "settings-clone-engine-\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        model = CloneEngineControlModel(snapshot: snapshot)
        self.send = send
        self.makeID = makeID
        self.now = now
    }

    public func receive(snapshot: CloneEngineStatus?) { model.receive(snapshot: snapshot) }
    public func receive(ack: CloneEngineAck) { model.receive(ack: ack) }
    public func expireUnanswered() { model.expireUnanswered(now: now()) }
    public var ackDeadline: Date? { model.ackDeadline }

    public func press(_ button: CloneEngineButton) {
        guard let command = model.press(button, id: makeID(), now: now()) else { return }
        dispatch(command)
    }

    public func setStartWithVoiceBar(_ value: Bool) {
        guard let command = model.setStartWithVoiceBar(value, id: makeID(), now: now()) else { return }
        dispatch(command)
    }

    public func presentation() -> CloneEnginePresentation { model.presentation(now: now()) }

    private func dispatch(_ command: CloneEngineCommand) {
        if !send(command) { model.sendFailed(id: command.id) }
    }
}
