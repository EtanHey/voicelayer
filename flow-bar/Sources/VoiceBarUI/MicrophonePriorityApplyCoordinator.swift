/// Keeps an edited microphone preference separate from the macOS default input.
/// Device IDs are resolved only at application time because CoreAudio IDs can change.
public final class MicrophonePriorityApplyCoordinator {
    private let resolveDeviceID: () -> String?
    private let applyDeviceID: (String) -> Bool
    private var pending = false
    private var lastAvailableDevices: [MicrophoneDevice]?

    public init(
        resolveDeviceID: @escaping () -> String?,
        applyDeviceID: @escaping (String) -> Bool
    ) {
        self.resolveDeviceID = resolveDeviceID
        self.applyDeviceID = applyDeviceID
    }

    public func requestApply(mode: VoiceMode, captureLive: Bool) {
        pending = true
        modeDidChange(mode, captureLive: captureLive)
    }

    public func availableDevicesDidChange(
        _ devices: [MicrophoneDevice],
        mode: VoiceMode,
        captureLive: Bool
    ) {
        guard devices != lastAvailableDevices else { return }
        lastAvailableDevices = devices
        requestApply(mode: mode, captureLive: captureLive)
    }

    public func modeDidChange(_ mode: VoiceMode, captureLive: Bool) {
        guard pending, mode == .idle, !captureLive,
              let deviceID = resolveDeviceID(), applyDeviceID(deviceID)
        else { return }
        pending = false
    }
}
