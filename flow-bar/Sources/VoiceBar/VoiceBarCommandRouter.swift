import Foundation

class VoiceBarCommandRouter {
    private let voiceState: VoiceState
    private let resetHotkeyState: () -> Void

    init(voiceState: VoiceState, resetHotkeyState: @escaping () -> Void = {}) {
        self.voiceState = voiceState
        self.resetHotkeyState = resetHotkeyState
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

    func handle(controlCommand command: SocketControlCommand) {
        NSLog("[VoiceBar] Socket control command received: %@ (mode: %@)", command.rawValue, voiceState.mode.rawValue)

        switch command {
        case .toggle:
            handleToggle()
        case .startRecording:
            handleStartRecording()
        case .stopRecording:
            handleStop()
        case .cancel:
            handleCancel()
        case .replay:
            handleReplay()
        }
    }

    func handlePrimaryTap() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }

    func handleCancel() {
        resetHotkeyState()
        voiceState.cancel()
    }

    func handleStop() {
        switch voiceState.mode {
        case .recording, .speaking:
            voiceState.stop()
        case .transcribing:
            handleCancel()
        default:
            return
        }
    }

    func handleReplay() {
        guard voiceState.mode == .idle else { return }
        voiceState.replay()
    }

    func handleHotkeyHoldStart() {
        switch voiceState.mode {
        case .idle, .error:
            voiceState.record(pressToTalk: true)
        case .transcribing:
            handleCancel()
        default:
            return
        }
    }

    func handleHotkeyHoldEnd(holdDuration: TimeInterval) {
        guard holdDuration > 0 else { return }
        handleStop()
    }

    func handleHotkeyDoubleTap() {
        // The first tap already sent the record intent. Double-tap only locks
        // the gesture state so releasing F5 does not stop the active recording.
    }

    func handleHotkeySingleTap() {
        switch voiceState.mode {
        case .recording, .speaking:
            voiceState.stop()
        case .transcribing:
            handleCancel()
        default:
            return
        }
    }

    private func handleToggle() {
        if voiceState.mode == .idle || voiceState.mode == .error {
            voiceState.record(pressToTalk: true)
        } else if voiceState.mode == .recording {
            voiceState.stop()
        } else if voiceState.mode == .transcribing {
            handleCancel()
        }
    }

    private func handleStartRecording() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }
}
