import Foundation

public enum IntentCommand: String {
    case stop
    case cancel
    case replay
    case retranscribeLast = "retranscribe_last"
    case toggle
    case record
    case setWhisperEffort = "set_whisper_effort"
}

public enum VoiceBarPerformanceEffort: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case accurate

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .fast:
            "Fast"
        case .balanced:
            "Balanced"
        case .accurate:
            "Accurate"
        }
    }
}

public enum IntentOutcome: String {
    case accept
    case noop
    case reject
}

public struct PendingIntent {
    public let id: String
    public let command: IntentCommand

    public init(id: String, command: IntentCommand) {
        self.id = id
        self.command = command
    }
}

public struct SocketAckEvent {
    public let command: IntentCommand
    public let outcome: IntentOutcome
    public let id: String
    public let reason: String?

    public init?(event: [String: Any]) {
        guard let commandRaw = event["command"] as? String,
              let command = IntentCommand(rawValue: commandRaw),
              let outcomeRaw = event["outcome"] as? String,
              let outcome = IntentOutcome(rawValue: outcomeRaw),
              let id = event["id"] as? String,
              !id.isEmpty
        else {
            return nil
        }

        self.command = command
        self.outcome = outcome
        self.id = id
        reason = event["reason"] as? String
    }
}

public enum CommandModeApplyResult: Equatable {
    case axVerified(String)
    case clipboardFallback(String)
    case failed(String)
}

public protocol BarCommandRouting {
    func handlePrimaryTap()
    func handleCancel()
    func handleStop()
    func handleReplay()
}

public enum HotkeyPermission: Equatable {
    case inputMonitoring
    case accessibility
    case microphone
}
