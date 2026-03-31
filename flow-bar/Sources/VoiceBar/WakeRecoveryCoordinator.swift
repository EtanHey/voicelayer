import Foundation

final class WakeRecoveryCoordinator {
    typealias Scheduler = (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void

    private let modeProvider: () -> VoiceMode
    private let schedule: Scheduler
    private let restartRecordingAudio: () -> Void
    private let resetHotkeyState: () -> Void

    init(
        modeProvider: @escaping () -> VoiceMode,
        schedule: @escaping Scheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        restartRecordingAudio: @escaping () -> Void,
        resetHotkeyState: @escaping () -> Void
    ) {
        self.modeProvider = modeProvider
        self.schedule = schedule
        self.restartRecordingAudio = restartRecordingAudio
        self.resetHotkeyState = resetHotkeyState
    }

    func handleWillSleep() {
        resetHotkeyState()
    }

    func handleDidWake() {
        schedule(0.5) { [modeProvider, restartRecordingAudio] in
            guard modeProvider() == .recording else { return }
            restartRecordingAudio()
        }
    }
}
