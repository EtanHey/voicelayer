import Foundation
import VoiceBarUI

struct SetRecordingHoldCommand: Equatable {
    static let commandName = "set_recording_hold"

    let engaged: Bool
    let id: String?

    init(engaged: Bool, id: String? = nil) {
        self.engaged = engaged
        self.id = id
    }

    init?(payload: [String: Any]) {
        guard payload["cmd"] as? String == Self.commandName,
              let engaged = payload["engaged"] as? Bool
        else {
            return nil
        }
        self.engaged = engaged
        id = payload["id"] as? String
    }

    var payload: [String: Any] {
        var result: [String: Any] = [
            "cmd": Self.commandName,
            "engaged": engaged,
        ]
        if let id {
            result["id"] = id
        }
        return result
    }
}

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
