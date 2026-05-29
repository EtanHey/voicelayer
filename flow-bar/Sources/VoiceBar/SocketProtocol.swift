import Foundation
import VoiceBarUI

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
