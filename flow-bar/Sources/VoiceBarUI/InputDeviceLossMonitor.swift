import CoreAudio
import Foundation

/// MICDROP2: which device one daemon capture is on, and whether its loss may be reported.
///
/// AIDEV-NOTE: sox binds the default input device once, when it opens, a few milliseconds around the
/// daemon's `recording` event. The binding is taken at that event (never at VoiceBar's optimistic UI
/// mode) and is trusted only when the default input did not move within `settleSeconds` either side
/// of it; otherwise sox may be on another device (Sol R1 #3). This cannot catch every callback order
/// (Sol R2 #1: the device-list callback first), so the daemon treats a report as evidence only: it
/// never stops a capture and is labelled only over a dead-flat tail (MICDROP3). A default change well
/// after the start does not move sox.
public struct InputDeviceLossBinding: Equatable {
    public static let settleSeconds: TimeInterval = 2

    public let captureID: Int
    public let deviceID: UInt32
    private let startedAt: Date
    public private(set) var ambiguous: Bool

    public init(captureID: Int, deviceID: UInt32, startedAt: Date, lastDefaultInputChange: Date?) {
        self.captureID = captureID
        self.deviceID = deviceID
        self.startedAt = startedAt
        ambiguous = lastDefaultInputChange.map { startedAt.timeIntervalSince($0) < Self.settleSeconds } ?? false
    }

    public mutating func defaultInputChanged(at date: Date) {
        if date.timeIntervalSince(startedAt) < Self.settleSeconds { ambiguous = true }
    }

    /// The daemon's `input_device_lost` reason; nil while the device is listed and alive, or unknown.
    public func lossReason(isListed: Bool, isAlive: Bool) -> String? {
        guard !ambiguous else { return nil }
        if !isListed { return "device-removed" }
        if !isAlive { return "device-not-alive" }
        return nil
    }
}

/// MICDROP2: CoreAudio evidence that a capture's input device went away. Read-only: it never writes
/// the default input (MicrophonePriorityApplyCoordinator is the only writer).
public final class InputDeviceLossMonitor {
    /// (reason, capture_id, device_id) for the `input_device_lost` command.
    private let report: (String, Int, UInt32) -> Void
    private var binding: InputDeviceLossBinding?
    private var lastDefaultInputChange: Date?
    private var captureListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(report: @escaping (String, Int, UInt32) -> Void) {
        self.report = report
        // App lifetime: a default change just before a capture starts makes its device ambiguous.
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) {
            [weak self] _, _ in
            guard let self else { return }
            let now = Date()
            lastDefaultInputChange = now
            binding?.defaultInputChanged(at: now)
            check()
        }
    }

    /// The daemon's authoritative `recording` event for capture `captureID`.
    public func beginCapture(captureID: Int) {
        guard binding?.captureID != captureID else { return }
        endCapture()
        guard let id = MicrophoneDeviceManager.selectedInputDeviceID().flatMap(AudioDeviceID.init) else { return }
        binding = InputDeviceLossBinding(
            captureID: captureID, deviceID: id, startedAt: Date(), lastDefaultInputChange: lastDefaultInputChange
        )
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        listen(id, kAudioDevicePropertyDeviceIsAlive)
    }

    public func endCapture() {
        for (object, address, block) in captureListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        captureListeners = []
        binding = nil
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            captureListeners.append((object, address, block))
        }
    }

    private func check() {
        guard let binding,
              let reason = binding.lossReason(isListed: Self.isListed(binding.deviceID), isAlive: Self.isAlive(binding.deviceID))
        else { return }
        endCapture()
        report(reason, binding.captureID, binding.deviceID)
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
