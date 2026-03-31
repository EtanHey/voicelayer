import Foundation

enum VoiceBarCommandRouter {
    static func handle(url: URL, voiceState: VoiceState) {
        guard url.scheme == "voicebar" else { return }

        switch url.host ?? "" {
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
            break
        }
    }
}
