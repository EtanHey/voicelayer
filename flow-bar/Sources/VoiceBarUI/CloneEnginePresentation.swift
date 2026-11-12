import Foundation
import Observation

// Settings › Speech: what the engine row shows for a `CloneEngineControlModel` (pill, copy, actions), and the
// view model the pane observes. The lifecycle facts come from V10; the words are ours.

public enum CloneEnginePillTone: Equatable, Sendable { case green, blue, grey, red }

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
    /// The outcome of the last request, or that one is waiting.
    public let note: String?
    public let noteIsProblem: Bool
    /// `nil` = unavailable (no snapshot); otherwise what the toggle shows, including a pending change.
    public let startWithVoiceBar: Bool?
    public let startWithVoiceBarEnabled: Bool

    /// Status pills read as text (spec accessibility rule).
    public var accessibilityStatus: String { "Clone engine: \(pill.lowercased())" }
}


extension CloneEngineControlModel {
    var note: (String, Bool)? {
        if let refusal { return (refusal.message, true) }
        if let inFlight { return (Self.sendingNote(inFlight.command.action), false) }
        if let accepted {
            if acceptedWithoutChange { return ("VoiceBar tried, and the engine is still as shown above.", true) }
            return Self.acceptedNote(accepted.command.action).map { ($0, false) }
        }
        if isForeign, snapshot?.state == .running { return (CloneEngineRefusal.foreignEngine.message, false) }
        return nil
    }

    public func presentation(now: Date, timeZone: TimeZone = .current,
                             locale: Locale = .current) -> CloneEnginePresentation {
        let note = self.note
        guard let snapshot else {
            return CloneEnginePresentation(
                pill: "Unavailable", tone: .grey, pulses: false, showsProgress: false,
                description: "VoiceBar hasn't reported the voice engine's status, so Settings can't control it yet.",
                actions: [], note: note?.0, noteIsProblem: note?.1 ?? false,
                startWithVoiceBar: nil, startWithVoiceBarEnabled: false
            )
        }
        let (pill, tone) = Self.pill(snapshot.state)
        return CloneEnginePresentation(
            pill: pill, tone: tone, pulses: snapshot.state == .starting,
            showsProgress: snapshot.state == .starting || snapshot.state == .restarting,
            description: Self.description(snapshot, now: now, timeZone: timeZone, locale: locale),
            actions: buttons().map { .init(button: $0, isEnabled: isEnabled($0)) },
            note: note?.0, noteIsProblem: note?.1 ?? false,
            startWithVoiceBar: pendingAutostart ?? snapshot.startWithVoiceBar,
            startWithVoiceBarEnabled: inFlight == nil
        )
    }

    static func pill(_ state: CloneEngineSnapshot.State) -> (String, CloneEnginePillTone) {
        switch state {
        case .running: ("Running", .green)
        case .starting: ("Starting", .blue)
        case .restarting: ("Restarting", .blue)
        case .stopped: ("Stopped", .grey)
        case .failed: ("Couldn't start", .red)
        }
    }

    static func description(_ snapshot: CloneEngineSnapshot, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let reason = snapshot.parsedReason
        switch snapshot.state {
        case .running:
            // `running` means the health endpoint answers; it says nothing about the weights being resident.
            guard let since = snapshot.sinceDate else { return "Ready." }
            return "Ready since \(sinceLabel(since, now: now, timeZone: timeZone, locale: locale))."
        case .starting:
            return "Loading your voice model. This can take up to two minutes."
        case .restarting:
            switch reason {
            case .engineExited?, .exitedEarly?: return "It stopped unexpectedly, so VoiceBar is starting it again."
            case .healthUnavailable?: return "It stopped answering, so VoiceBar is starting it again."
            case .startupTimeout?: return "It took too long to start, so VoiceBar is trying again."
            case .launchFailed?: return "It couldn't launch, so VoiceBar is trying again."
            default: return "VoiceBar is starting it again."
            }
        case .stopped:
            return "Long replies use the fast voice until it runs."
        case .failed:
            return failedDescription(reason)
        }
    }

    static func failedDescription(_ reason: CloneEngineReason?) -> String {
        switch reason {
        case .portOccupied?: "Another program is using the voice engine's port, so VoiceBar can't start its own."
        case .pythonMissing?: "The voice engine's Python runtime is missing. Reinstall VoiceLayer, then try again."
        case .scriptMissing?, .scriptUnresolved?:
            "The voice engine's files are missing from this install. Reinstall VoiceLayer, then try again."
        case .launchFailed?: "VoiceBar couldn't launch the voice engine."
        case .exitedEarly?, .engineExited?: "The voice engine quit unexpectedly."
        case .startupTimeout?: "The voice engine didn't answer within two minutes of starting."
        case .healthUnavailable?:
            "The voice engine stopped answering. It's still running, so a reply in progress can finish."
        case .stopTimeout?: "The voice engine didn't stop when asked. It's still running."
        case .unrecognized(let code)?: "The voice engine couldn't start. VoiceBar reported \u{201C}\(code)\u{201D}."
        case .adoptedExisting?, .userStop?, .voicebarQuit?, nil:
            "The voice engine couldn't start, and VoiceBar didn't say why."
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

/// The view model the Speech pane observes. The app feeds it V10 snapshots and acknowledgements and gives it a
/// sender; tests give it fakes.
@Observable
public final class CloneEngineControlViewModel {
    public private(set) var model: CloneEngineControlModel
    private let send: (CloneEngineCommand) -> Bool
    private let makeID: () -> String
    private let now: () -> Date

    public init(
        snapshot: CloneEngineSnapshot? = nil,
        send: @escaping (CloneEngineCommand) -> Bool,
        makeID: @escaping () -> String = { "settings-clone-engine-\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        model = CloneEngineControlModel(snapshot: snapshot)
        self.send = send
        self.makeID = makeID
        self.now = now
    }

    public func receive(snapshot: CloneEngineSnapshot?) { model.receive(snapshot: snapshot) }

    /// Only `clone_engine` acknowledgements are read; anything else is ignored.
    public func receive(ack: SocketAckEvent) {
        guard ack.command == .cloneEngine else { return }
        model.receive(ackID: ack.id, accepted: ack.outcome == .accept, reason: ack.reason, now: now())
    }

    public func expire() { model.expire(now: now()) }
    public var nextDeadline: Date? { model.nextDeadline }

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
