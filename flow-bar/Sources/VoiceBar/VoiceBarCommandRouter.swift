import Foundation
import VoiceBarUI

class VoiceBarCommandRouter: BarCommandRouting {
    private let voiceState: VoiceState
    private let resetHotkeyState: () -> Void
    private let showVoiceBar: () -> Void
    private let openSettings: (SettingsTab?) -> Void

    init(
        voiceState: VoiceState,
        resetHotkeyState: @escaping () -> Void = {},
        showVoiceBar: @escaping () -> Void = {},
        openSettings: @escaping (SettingsTab?) -> Void = { _ in }
    ) {
        self.voiceState = voiceState
        self.resetHotkeyState = resetHotkeyState
        self.showVoiceBar = showVoiceBar
        self.openSettings = openSettings
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
        case "cancel":
            handleCancel()
        case "show":
            handleShowVoiceBar()
        case "settings":
            // voicebar://settings opens Settings; voicebar://settings/<tab> opens that tab. An unknown
            // tab still opens Settings rather than doing nothing.
            openSettings(url.pathComponents.dropFirst().first.flatMap(SettingsTab.init(urlComponent:)))
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

    var shouldHandleEscape: Bool {
        voiceState.mode == .recording ||
            voiceState.mode == .transcribing ||
            voiceState.mode == .speaking
    }

    /// One owned Escape interrupts either direction through existing commands.
    /// Playback uses stop so the teleprompter remains visible until the daemon
    /// confirms playback idle; recording uses cancel to discard the capture.
    func handleEscape() {
        switch voiceState.mode {
        case .speaking:
            handleStop()
        case .recording, .transcribing:
            handleCancel()
        default:
            return
        }
    }

    func handleStop() {
        switch voiceState.mode {
        case .recording, .speaking:
            resetHotkeyState()
            voiceState.stop()
        case .transcribing:
            handleCancel()
        default:
            return
        }
    }

    func handleReplay() {
        guard voiceState.mode == .idle || voiceState.mode == .speaking else { return }
        voiceState.replay()
    }

    func handleRetranscribeHistoryEntry(recordingPath: String) {
        guard voiceState.mode == .idle else { return }
        voiceState.retranscribeHistoryEntry(recordingPath: recordingPath)
    }

    func handleShowVoiceBar() {
        showVoiceBar()
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
            handleStop()
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
            handleStop()
        } else if voiceState.mode == .transcribing {
            handleCancel()
        }
    }

    private func handleStartRecording() {
        guard voiceState.mode == .idle || voiceState.mode == .error else { return }
        voiceState.record(pressToTalk: true)
    }
}
