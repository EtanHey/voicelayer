import AppKit
import CoreAudio
import Foundation

public struct MicrophoneDevice: Equatable {
    public var id: String
    public var name: String
}

public struct MicrophoneDeviceOption: Equatable {
    public var id: String
    public var title: String
    public var isSelected: Bool
}

public final class PillContextMenuController: NSObject {
    public var transcriptProvider: () -> String = { "" }
    public var recentTranscriptionsProvider: () -> [String] = { [] }
    public var transcriptionVocabularyTermsProvider: () -> [String] = { [] }
    public var transcriptionVocabularyAliasesProvider: () -> [STTVocabularyAliasPreview] = { [] }
    public var availableDevicesProvider: () -> [MicrophoneDevice] = { [] }
    public var selectedDeviceIDProvider: () -> String? = { nil }
    public var anchorModeProvider: () -> VoiceBarAnchorMode = { .follow }

    public var onOpenSettings: () -> Void = {}
    public var onSnooze: () -> Void = {}
    public var onUnsnooze: () -> Void = {}
    public var isSnoozedProvider: () -> Bool = { false }
    public var onSelectDevice: (String) -> Void = { _ in }
    public var onTranscribeLatestRecording: () -> Void = {}
    public var onAddSelectionToDictionary: () -> Void = {}
    public var onPasteLastTranscript: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteTranscript: (String) -> Void = { _ in }
    public var onSelectAnchorMode: (VoiceBarAnchorMode) -> Void = { _ in }
    public var onQuit: () -> Void = {}

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

        let preferencesItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferencesItem.submenu = makePreferencesSubmenu()
        menu.addItem(preferencesItem)

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

        let vocabularyItem = NSMenuItem(title: "Transcription Vocabulary", action: nil, keyEquivalent: "")
        vocabularyItem.submenu = makeTranscriptionVocabularySubmenu()
        menu.addItem(vocabularyItem)

        return menu
    }

    public func makePreferencesSubmenu() -> NSMenu {
        let menu = NSMenu()

        let anchorItem = NSMenuItem(title: "Anchor", action: nil, keyEquivalent: "")
        anchorItem.submenu = makeAnchorSubmenu()
        menu.addItem(anchorItem)

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        menu.addItem(microphoneItem)

        return menu
    }

    public func makeAnchorSubmenu() -> NSMenu {
        let menu = NSMenu()
        let selectedMode = anchorModeProvider()
        for mode in VoiceBarAnchorMode.anchorMenuModes {
            let item = NSMenuItem(
                title: mode.anchorMenuTitle,
                action: #selector(handleSelectAnchorMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == selectedMode ? .on : .off
            menu.addItem(item)
        }
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

    public func makeTranscriptionVocabularySubmenu() -> NSMenu {
        let menu = NSMenu()
        let terms = transcriptionVocabularyTermsProvider()
        let aliases = transcriptionVocabularyAliasesProvider()

        guard !terms.isEmpty || !aliases.isEmpty else {
            let empty = NSMenuItem(title: "Vocabulary not loaded yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        if !terms.isEmpty {
            let termsItem = NSMenuItem(title: "Terms", action: nil, keyEquivalent: "")
            termsItem.submenu = makeTranscriptionVocabularyTermsSubmenu(terms)
            menu.addItem(termsItem)
        }

        if !aliases.isEmpty {
            let aliasesItem = NSMenuItem(title: "Corrections", action: nil, keyEquivalent: "")
            aliasesItem.submenu = makeTranscriptionVocabularyAliasesSubmenu(aliases)
            menu.addItem(aliasesItem)
        }

        return menu
    }

    private func makeTranscriptionVocabularyTermsSubmenu(_ terms: [String]) -> NSMenu {
        let menu = NSMenu()
        for term in terms {
            let item = NSMenuItem(title: term, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    private func makeTranscriptionVocabularyAliasesSubmenu(
        _ aliases: [STTVocabularyAliasPreview]
    ) -> NSMenu {
        let menu = NSMenu()
        for alias in aliases {
            let item = NSMenuItem(
                title: "\(alias.from) → \(alias.to)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
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

    public static func deviceOptions(
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

    @objc private func handleQuit() {
        onQuit()
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

    @objc private func handleSelectAnchorMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = VoiceBarAnchorMode(rawValue: rawValue)
        else { return }
        onSelectAnchorMode(mode)
    }

    @objc private func handleAddSelectionToDictionary() {
        onAddSelectionToDictionary()
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
                name: deviceName(for: deviceID) ?? "Unknown Microphone"
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
