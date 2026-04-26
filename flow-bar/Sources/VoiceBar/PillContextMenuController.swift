import AppKit
import CoreAudio
import Foundation

struct MicrophoneDevice: Equatable {
    var id: String
    var name: String
}

struct MicrophoneDeviceOption: Equatable {
    var id: String
    var title: String
    var isSelected: Bool
}

final class PillContextMenuController: NSObject {
    var transcriptProvider: () -> String = { "" }
    var recentTranscriptionsProvider: () -> [String] = { [] }
    var availableDevicesProvider: () -> [MicrophoneDevice] = { [] }
    var selectedDeviceIDProvider: () -> String? = { nil }

    var onSnooze: () -> Void = {}
    var onUnsnooze: () -> Void = {}
    var isSnoozedProvider: () -> Bool = { false }
    var onSelectDevice: (String) -> Void = { _ in }
    var onPasteLastTranscript: () -> Void = {}
    var onQuit: () -> Void = {}

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        if isSnoozedProvider() {
            let unsnoozeItem = NSMenuItem(
                title: "Show VoiceBar",
                action: #selector(handleUnsnooze),
                keyEquivalent: ""
            )
            unsnoozeItem.target = self
            menu.addItem(unsnoozeItem)
        } else {
            let snoozeItem = NSMenuItem(
                title: "Hide for 1 hour",
                action: #selector(handleSnooze),
                keyEquivalent: ""
            )
            snoozeItem.target = self
            menu.addItem(snoozeItem)
        }

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        menu.addItem(microphoneItem)

        let historyItem = NSMenuItem(title: "Transcript History", action: nil, keyEquivalent: "")
        historyItem.submenu = makeTranscriptHistorySubmenu()
        menu.addItem(historyItem)

        let pasteItem = NSMenuItem(
            title: "Paste last transcript",
            action: #selector(handlePasteLastTranscript),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = Self.isPasteEnabled(transcript: transcriptProvider())
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VoiceBar",
            action: #selector(handleQuit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func makeTranscriptHistorySubmenu() -> NSMenu {
        let menu = NSMenu()
        let recent = recentTranscriptionsProvider()

        guard !recent.isEmpty else {
            let empty = NSMenuItem(title: "No recent transcriptions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for (index, transcript) in recent.enumerated() {
            if index == 0 {
                let latest = NSMenuItem(title: "Latest", action: nil, keyEquivalent: "")
                latest.isEnabled = false
                menu.addItem(latest)
            }

            let item = NSMenuItem(title: transcript, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        return menu
    }

    func makeMicrophoneSubmenu() -> NSMenu {
        let menu = NSMenu()
        let selectedID = selectedDeviceIDProvider()
        let options = Self.deviceOptions(
            devices: availableDevicesProvider(),
            selectedID: selectedID
        )

        if options.isEmpty {
            let empty = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for option in options {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(handleSelectDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = option.isSelected ? .on : .off
            item.representedObject = option.id
            menu.addItem(item)
        }

        return menu
    }

    static func deviceOptions(
        devices: [MicrophoneDevice],
        selectedID: String?
    ) -> [MicrophoneDeviceOption] {
        devices.map {
            MicrophoneDeviceOption(
                id: $0.id,
                title: $0.name,
                isSelected: $0.id == selectedID
            )
        }
    }

    static func isPasteEnabled(transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func handleSnooze() {
        onSnooze()
    }

    @objc private func handleUnsnooze() {
        onUnsnooze()
    }

    @objc private func handlePasteLastTranscript() {
        onPasteLastTranscript()
    }

    @objc private func handleQuit() {
        onQuit()
    }

    @objc private func handleSelectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectDevice(id)
    }
}

enum MicrophoneDeviceManager {
    static func availableInputDevices() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr
        else { return [] }

        return devices.compactMap { deviceID in
            guard isInputDevice(deviceID) else { return nil }
            return MicrophoneDevice(
                id: String(deviceID),
                name: deviceName(for: deviceID) ?? "Unknown Microphone"
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func selectedInputDeviceID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return String(deviceID)
    }

    @discardableResult
    static func selectInputDevice(id: String) -> Bool {
        guard let deviceID = AudioDeviceID(id) else { return false }
        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        return status == noErr
    }

    private static func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }
}
