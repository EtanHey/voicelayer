import Foundation

enum SocketControlCommand: String, Equatable {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case toggle
    case cancel
    case replay

    init?(event: [String: Any]) {
        guard event["type"] as? String == "control",
              let command = event["command"] as? String
        else {
            return nil
        }
        self.init(rawValue: command)
    }
}

enum IntentCommand: String {
    case stop
    case cancel
    case replay
    case retranscribeLast = "retranscribe_last"
    case toggle
    case record
}

enum IntentOutcome: String {
    case accept
    case noop
    case reject
}

struct PendingIntent {
    let id: String
    let command: IntentCommand
}

struct SocketAckEvent {
    let command: IntentCommand
    let outcome: IntentOutcome
    let id: String
    let reason: String?

    init?(event: [String: Any]) {
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

enum VoiceBarLocalControlCommand: String, Equatable {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case toggle
    case pasteLastTranscript = "paste-last-transcript"

    init?(payload: [String: Any]) {
        guard let type = payload["type"] as? String,
              type == "control",
              let rawCommand = payload["command"] as? String,
              let command = Self(rawValue: rawCommand)
        else {
            return nil
        }

        self = command
    }
}
