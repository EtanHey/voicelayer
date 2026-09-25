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
    public var recentTranscriptionEntriesProvider: () -> [RecentTranscriptionEntry] = { [] }
    public var now: () -> Date = { Date() }
    public var availableDevicesProvider: () -> [MicrophoneDevice] = { [] }
    public var selectedDeviceIDProvider: () -> String? = { nil }

    public var onOpenSettings: () -> Void = {}
    public var onSnooze: () -> Void = {}
    public var onUnsnooze: () -> Void = {}
    public var isSnoozedProvider: () -> Bool = { false }
    public var onSelectDevice: (String) -> Void = { _ in }
    public var onQuit: () -> Void = {}
    public var onPasteLastTranscript: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteTranscript: (String) -> Void = { _ in }

    /// Etan's approved spec §3 (p03-design-spec-approval/spec.md), item for item: Settings… · Hide for 1 hour ·
    /// — · Recent Transcriptions › · Paste/Copy Last Transcript · — · Microphone › · — · Quit VoiceBar.
    public func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
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

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        historyItem.submenu = makeRecentTranscriptsSubmenu()
        menu.addItem(historyItem)

        let hasTranscript = Self.isPasteEnabled(transcript: transcriptProvider())
        let pasteItem = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(handlePasteLastTranscript),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = hasTranscript
        menu.addItem(pasteItem)

        let copyItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(handleCopyLastTranscript),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasTranscript
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        if #available(macOS 14.4, *) {
            microphoneItem.subtitle = currentMicrophoneTitle()
        }
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoiceBar", action: #selector(handleQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// The device the Microphone submenu checks, from the same filtered list (#141).
    private func currentMicrophoneTitle() -> String? {
        let devices = availableDevicesProvider()
        let selectedID = selectedDeviceIDProvider()
        if let hidden = MicrophoneDevice.hiddenInUse(devices, selectedID: selectedID) {
            return MicrophoneDevice.hiddenDeviceLabel(hidden.name)
        }
        return MicrophoneDevice.pickable(devices).first { $0.id == selectedID }?.name
    }

    public func makeRecentTranscriptsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let entries = recentTranscriptionEntriesProvider()

        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        let now = now()
        for entry in entries {
            let item = NSMenuItem(
                title: Self.recentTranscriptMenuTitle(
                    for: entry.text,
                    time: VoiceBarRelativeTime.label(entry.createdAt, now: now)
                ),
                action: #selector(handlePasteRecentTranscript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.text
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

    /// Spec §3: time + the first words; no "Latest —".
    public static func recentTranscriptMenuTitle(for transcript: String, time: String?) -> String {
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
        return time.map { "\($0) · \(preview)" } ?? preview
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

    @objc private func handleQuit() {
        onQuit()
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
