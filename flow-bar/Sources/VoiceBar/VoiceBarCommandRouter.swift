import Foundation

class VoiceBarCommandRouter {
    private let voiceState: VoiceState

    init(voiceState: VoiceState) {
        self.voiceState = voiceState
    }

    func handle(url: URL) {
        guard url.scheme == "voicebar" else {
            NSLog("[VoiceBar] URL scheme mismatch: %@", url.absoluteString)
            return
        }

        let command = url.host ?? ""
        NSLog("[VoiceBar] URL command received: %@ (mode: %@)", command, voiceState.mode.rawValue)

        switch command {
        case "toggle":
            handleToggle()
        case "start-recording":
            handleStartRecording()
        case "stop-recording":
            handleStop()
        default:
            NSLog("[VoiceBar] Unknown URL command: %@", command)
        }
    }

    func handlePrimaryTap() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }

    func handleCancel() {
        voiceState.cancel()
    }

    func handleStop() {
        guard voiceState.mode == .recording || voiceState.mode == .speaking else { return }
        voiceState.stop()
    }

    func handleReplay() {
        guard voiceState.mode == .idle else { return }
        voiceState.replay()
    }

    func handleHotkeyHoldStart() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }

    func handleHotkeyHoldEnd(holdDuration: TimeInterval) {
        guard holdDuration > 0 else { return }
        voiceState.stop()
    }

    func handleHotkeyDoubleTap() {
        handleToggle()
    }

    private func handleToggle() {
        if voiceState.mode == .idle || voiceState.mode == .error {
            voiceState.record(pressToTalk: true)
        } else if voiceState.mode == .recording {
            voiceState.stop()
        }
    }

    private func handleStartRecording() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }
}
