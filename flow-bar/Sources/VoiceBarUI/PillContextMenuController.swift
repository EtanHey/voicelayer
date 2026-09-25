import AppKit
import CoreAudio
import Foundation

public struct MicrophoneDevice: Equatable {
    public var id: String
    public var name: String
    public var uid: String?
    public var isVirtualOrAggregateTransport: Bool?

    public init(id: String, name: String, uid: String? = nil, isVirtualOrAggregateTransport: Bool? = nil) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isVirtualOrAggregateTransport = isVirtualOrAggregateTransport
    }
}

/// AIDEV-NOTE: The ONE rule for which input devices a user may pick. The menu-bar popover, the right-click
/// Microphone submenu and Settings' priority list all use it (R4 UI pass #2: the menus used to list VoiceBar's
/// own `CADefaultDeviceAggregate-<pid>-0` and the Teams/Zoom loopbacks while Settings hid them).
public extension MicrophoneDevice {
    /// CoreAudio's transport type decides when it is known; the device identity is only the fallback. (That
    /// fallback's "aggregate" substring would also hide a user-built aggregate, but only when the transport
    /// read fails, and then an aggregate is the safer guess.)
    static func isVirtualOrAggregate(uid: String?, name: String, transport: Bool?) -> Bool {
        if let transport { return transport }
        let identity = "\(uid ?? "") \(name)".lowercased()
        return [
            "cadefaultdeviceaggregate-", "aggregate", "virtual", "blackhole", "loopback",
            "microsoft teams audio", "msteamsaudio", "zoomaudiodevice",
        ].contains { identity.contains($0) }
    }

    var isVirtualOrAggregate: Bool {
        Self.isVirtualOrAggregate(uid: uid, name: name, transport: isVirtualOrAggregateTransport)
    }

    /// The devices every microphone picker offers, in the order given.
    static func pickable(_ devices: [MicrophoneDevice]) -> [MicrophoneDevice] {
        devices.filter { !$0.isVirtualOrAggregate }
    }

    /// The selected device when it is one the pickers hide (#141 review): every picker still shows it, checked
    /// and not selectable, so the user sees what is actually recording and can switch away.
    static func hiddenInUse(_ devices: [MicrophoneDevice], selectedID: String?) -> MicrophoneDevice? {
        guard let selectedID, let selected = devices.first(where: { $0.id == selectedID }),
              selected.isVirtualOrAggregate
        else { return nil }
        return selected
    }

    /// The one label for a hidden device in use, shared by the popover, the right-click menu and Settings.
    static func hiddenDeviceLabel(_ name: String) -> String {
        "\(name) (hidden device)"
    }

    static func hiddenInUseTitle(_ name: String) -> String {
        "In use: \(hiddenDeviceLabel(name))"
    }
}

public struct MicrophoneDeviceOption: Equatable {
    public var id: String
    public var title: String
    public var isSelected: Bool
    public var isEnabled: Bool = true
}

public final class PillContextMenuController: NSObject {
    public var transcriptProvider: () -> String = { "" }
    public var recentTranscriptionsProvider: () -> [String] = { [] }
    public var availableDevicesProvider: () -> [MicrophoneDevice] = { [] }
    public var selectedDeviceIDProvider: () -> String? = { nil }

    public var onOpenSettings: () -> Void = {}
    public var onSnooze: () -> Void = {}
    public var onUnsnooze: () -> Void = {}
    public var isSnoozedProvider: () -> Bool = { false }
    public var onSelectDevice: (String) -> Void = { _ in }
    public var onTranscribeLatestRecording: () -> Void = {}
    public var onAddSelectionToDictionary: () -> Void = {}
    public var onOpenDictionary: () -> Void = {}
    public var onPasteLastTranscript: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteTranscript: (String) -> Void = { _ in }

    public func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(handleOpenSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

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

        let historyItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        historyItem.submenu = makeRecentTranscriptsSubmenu()
        menu.addItem(historyItem)

        let pasteItem = NSMenuItem(
            title: "Paste last transcript",
            action: #selector(handlePasteLastTranscript),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = Self.isPasteEnabled(transcript: transcriptProvider())
        menu.addItem(pasteItem)

        let copyItem = NSMenuItem(
            title: "Copy last transcript",
            action: #selector(handleCopyLastTranscript),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = Self.isPasteEnabled(transcript: transcriptProvider())
        menu.addItem(copyItem)

        let toolsItem = NSMenuItem(title: "Transcription Tools", action: nil, keyEquivalent: "")
        toolsItem.submenu = makeTranscriptionToolsSubmenu()
        menu.addItem(toolsItem)

        // Preferences held only this once Anchor and Morph Prototype went (R4 UI pass #4), so it sits at the top.
        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        menu.addItem(microphoneItem)

        return menu
    }

    public func makeTranscriptionToolsSubmenu() -> NSMenu {
        let menu = NSMenu()

        let recoverItem = NSMenuItem(
            title: "Transcribe latest recording",
            action: #selector(handleTranscribeLatestRecording),
            keyEquivalent: ""
        )
        recoverItem.target = self
        menu.addItem(recoverItem)

        let addDictionaryItem = NSMenuItem(
            title: "Add to Dictionary…",
            action: #selector(handleAddSelectionToDictionary),
            keyEquivalent: ""
        )
        addDictionaryItem.target = self
        menu.addItem(addDictionaryItem)

        // One item instead of the old read-only Terms/Corrections wall (R4 UI pass #5).
        let openDictionaryItem = NSMenuItem(
            title: "Open Dictionary…",
            action: #selector(handleOpenDictionary),
            keyEquivalent: ""
        )
        openDictionaryItem.target = self
        menu.addItem(openDictionaryItem)

        return menu
    }

    public func makeRecentTranscriptsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let transcripts = recentTranscriptionsProvider()

        guard !transcripts.isEmpty else {
            let empty = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for (index, transcript) in transcripts.enumerated() {
            let item = NSMenuItem(
                title: Self.recentTranscriptMenuTitle(for: transcript, isLatest: index == 0),
                action: #selector(handlePasteRecentTranscript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = transcript
            menu.addItem(item)
        }

        return menu
    }

    public func makeMicrophoneSubmenu() -> NSMenu {
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
                action: option.isEnabled ? #selector(handleSelectDevice(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = option.isEnabled ? self : nil
            item.isEnabled = option.isEnabled
            item.state = option.isSelected ? .on : .off
            item.representedObject = option.id
            menu.addItem(item)
            if !option.isEnabled {
                menu.addItem(.separator())
            }
        }

        return menu
    }

    public static func deviceOptions(
        devices: [MicrophoneDevice],
        selectedID: String?
    ) -> [MicrophoneDeviceOption] {
        let inUse = MicrophoneDevice.hiddenInUse(devices, selectedID: selectedID).map {
            MicrophoneDeviceOption(
                id: $0.id,
                title: MicrophoneDevice.hiddenInUseTitle($0.name),
                isSelected: true,
                isEnabled: false
            )
        }
        return (inUse.map { [$0] } ?? []) + MicrophoneDevice.pickable(devices).map {
            MicrophoneDeviceOption(
                id: $0.id,
                title: $0.name,
                isSelected: $0.id == selectedID
            )
        }
    }

    public static func isPasteEnabled(transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func recentTranscriptMenuTitle(for transcript: String, isLatest: Bool) -> String {
        let flattened = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewLimit = 54
        let preview = trimmed.count > previewLimit
            ? String(trimmed.prefix(previewLimit - 1)) + "…"
            : trimmed
        return isLatest ? "Latest — \(preview)" : preview
    }

    @objc private func handleOpenSettings() {
        onOpenSettings()
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

    @objc private func handleCopyLastTranscript() {
        onCopyLastTranscript()
    }

    @objc private func handlePasteRecentTranscript(_ sender: NSMenuItem) {
        guard let transcript = sender.representedObject as? String else { return }
        onPasteTranscript(transcript)
    }

    @objc private func handleSelectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectDevice(id)
    }

    @objc private func handleTranscribeLatestRecording() {
        onTranscribeLatestRecording()
    }

    @objc private func handleAddSelectionToDictionary() {
        onAddSelectionToDictionary()
    }

    @objc private func handleOpenDictionary() {
        onOpenDictionary()
    }
}

public enum MicrophoneDeviceManager {
    public static func availableInputDevices() -> [MicrophoneDevice] {
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
                name: deviceName(for: deviceID) ?? "Unknown Microphone",
                uid: deviceUID(for: deviceID),
                isVirtualOrAggregateTransport: isVirtualOrAggregateTransport(for: deviceID)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isVirtualOrAggregateTransport(for deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType) == noErr
        else { return nil }
        return transportType == kAudioDeviceTransportTypeAggregate ||
            transportType == kAudioDeviceTransportTypeVirtual
    }

    public static func selectedInputDeviceID() -> String? {
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
    public static func selectInputDevice(id: String) -> Bool {
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
        stringProperty(kAudioObjectPropertyName, for: deviceID)
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
