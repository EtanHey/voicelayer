import CoreAudio
import Foundation

/// MICDROP2: OS evidence that the input device a capture opened went away mid-recording.
///
/// AIDEV-NOTE: sox binds the default input device once, when it opens. On any CoreAudio change
/// during a capture (the device list, that device's IsAlive, the default input) this re-checks that
/// device and reports only when it has left the device list or is no longer alive. A default-input
/// change alone (AirPods connecting, a priority apply) leaves sox on a live device, so it reports
/// nothing: stopping then would cut Etan off mid-thought. Read-only: it never writes the default
/// input (MicrophonePriorityApplyCoordinator is the only writer).
public final class InputDeviceLossMonitor {
    /// The daemon's `input_device_lost` reasons; nil while the device is listed and alive.
    public static func lossReason(isListed: Bool, isAlive: Bool) -> String? {
        if !isListed { return "device-removed" }
        if !isAlive { return "device-not-alive" }
        return nil
    }

    private let report: (String) -> Void
    private var capturing = false
    private var deviceID: AudioDeviceID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(report: @escaping (String) -> Void) {
        self.report = report
    }

    /// Follows VoiceState's mode: listens from a capture's start until it ends, reporting at most once.
    public func setCapturing(_ isCapturing: Bool) {
        guard isCapturing != capturing else { return }
        capturing = isCapturing
        if isCapturing {
            guard let id = MicrophoneDeviceManager.selectedInputDeviceID().flatMap(AudioDeviceID.init)
            else { return }
            deviceID = id
            let system = AudioObjectID(kAudioObjectSystemObject)
            listen(system, kAudioHardwarePropertyDevices)
            listen(system, kAudioHardwarePropertyDefaultInputDevice)
            listen(id, kAudioDevicePropertyDeviceIsAlive)
        } else {
            removeListeners()
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners = []
        deviceID = nil
    }

    private func check() {
        guard let id = deviceID,
              let reason = Self.lossReason(isListed: Self.isListed(id), isAlive: Self.isAlive(id))
        else { return }
        removeListeners()
        report(reason)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func isListed(_ id: AudioDeviceID) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        // Unreadable list: no evidence either way, so the device counts as present.
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return true }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return true }
        return devices.contains(id)
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr else { return true }
        return alive != 0
    }
}
