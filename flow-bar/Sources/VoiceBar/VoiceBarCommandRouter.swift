import Foundation

enum VoiceBarCommandRouter {
    static func handle(url: URL, voiceState: VoiceState) {
        guard url.scheme == "voicebar" else {
            NSLog("[VoiceBar] URL scheme mismatch: %@", url.absoluteString)
            return
        }

        let command = url.host ?? ""
        NSLog("[VoiceBar] URL command received: %@ (mode: %@)", command, voiceState.mode.rawValue)

        switch command {
        case "toggle":
            if voiceState.mode == .idle {
                voiceState.record()
            } else if voiceState.mode == .recording {
                voiceState.stop()
            }
        case "start-recording":
            if voiceState.mode == .idle {
                voiceState.record()
            }
        case "stop-recording":
            if voiceState.mode == .recording {
                voiceState.stop()
            }
        default:
            NSLog("[VoiceBar] Unknown URL command: %@", command)
        }
    }
}
