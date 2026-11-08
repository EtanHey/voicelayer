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

/// AIDEV-NOTE: The ONE rule for which input devices a user may pick (R4 UI pass #2: the menus used to list
/// VoiceBar's own `CADefaultDeviceAggregate-<pid>-0` and the Teams/Zoom loopbacks while Settings hid them).
/// Since D2 (2026-09-25) Settings' priority list is the only picker; the menu and popover show its default
/// read-only, with `hiddenDeviceLabel` when that default is a hidden device.
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

    /// The one label for a hidden device in use, shared by the popover, the right-click menu and Settings.
    static func hiddenDeviceLabel(_ name: String) -> String {
        "\(name) (hidden device)"
    }
}

public final class PillContextMenuController: NSObject {
    public var transcriptProvider: () -> String = { "" }
    public var recentTranscriptionEntriesProvider: () -> [RecentTranscriptionEntry] = { [] }
    public var now: () -> Date = { Date() }
    /// The microphone-priority default (the name Settings shows as "Next dictation").
    public var defaultMicrophoneNameProvider: () -> String? = { nil }

    public var onOpenSettings: () -> Void = {}
    public var onSnooze: () -> Void = {}
    public var onUnsnooze: () -> Void = {}
    public var isSnoozedProvider: () -> Bool = { false }
    /// Opens Settings › General › Microphone priority. There is no direct device pick here (D2).
    public var onChangeMicrophone: () -> Void = {}
    public var onQuit: () -> Void = {}
    public var onPasteLastTranscript: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var canRetranscribeLatestProvider: () -> Bool = { false }
    public var onRetranscribeLatest: () -> Void = {}
    public var onPasteTranscript: (String) -> Void = { _ in }
    /// 2.3 U2: the microphones the notch picker lists, in priority order (connected and visible only).
    public var microphonePickerRowsProvider: () -> [MicrophonePickerRow] = { [] }
    /// Etan's approved spec §3 (p03-design-spec-approval/spec.md), item for item: Settings… · Hide for 1 hour ·
    /// — · Recent Transcriptions › · Paste/Copy Last Transcript · Re-transcribe latest · — · Microphone › · — · Quit
    /// VoiceBar.
    public func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ""
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

        let retranscribeItem = NSMenuItem(
            title: "Re-transcribe latest",
            action: #selector(handleRetranscribeLatest),
            keyEquivalent: ""
        )
        retranscribeItem.target = self
        retranscribeItem.isEnabled = canRetranscribeLatestProvider()
        menu.addItem(retranscribeItem)

        menu.addItem(.separator())

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        if let name = defaultMicrophoneNameProvider() {
            let subtitle = Self.fittedMenuText(name, middle: true)
            microphoneItem.toolTip = name
            // AppKit otherwise sizes this row for "Microphone", clipping its subtitle.
            menu.minimumWidth = Self.textWidth(subtitle) + 64
            if #available(macOS 14.4, *) {
                microphoneItem.subtitle = subtitle
            }
        }
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoiceBar", action: #selector(handleQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    public var updateStatusProvider: () -> String? = { nil }
    public static func versionLine(version: String, updateStatus: String?) -> String {
        let title = version.isEmpty ? "VoiceBar" : "VoiceBar \(version)"
        return updateStatus.map { "\(title) · \($0)" } ?? title
    }

    static var versionTextColor: NSColor { .labelColor.withAlphaComponent(0.65) }

    /// Static metadata needs readable text even though it is not an enabled command.
    public static func versionItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 13)
        label.textColor = versionTextColor
        label.frame = NSRect(x: 12, y: 4, width: label.fittingSize.width, height: 18)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.maxX + 12, height: 26))
        row.addSubview(label)
        item.view = row
        item.isEnabled = false
        return item
    }

    public func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action, enabled) in [
            ("Copy last transcript", #selector(handleCopyLastTranscript), Self.isPasteEnabled(transcript: transcriptProvider())),
            ("Paste last transcript", #selector(handlePasteLastTranscript), Self.isPasteEnabled(transcript: transcriptProvider())),
            ("Settings…", #selector(handleOpenSettings), true),
            (isSnoozedProvider() ? "Show VoiceBar" : "Hide notch for 1 hour",
             isSnoozedProvider() ? #selector(handleUnsnooze) : #selector(handleSnooze), true),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        // macOS appends its own Quit; adding another would duplicate the Dock command.
        menu.insertItem(.separator(), at: 2)
        return menu
    }

    public var versionProvider: () -> String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    public func makeNotchMenu() -> NSMenu {
        let menu = makeDockMenu()
        let again = NSMenuItem(title: "Transcribe latest again", action: #selector(handleRetranscribeLatest), keyEquivalent: "")
        again.target = self
        again.isEnabled = canRetranscribeLatestProvider()
        menu.insertItem(again, at: 2)
        menu.item(withTitle: "Settings…")?.keyEquivalent = ","
        menu.item(withTitle: "Hide notch for 1 hour")?.title = "Hide for 1 hour"
        menu.insertItem(.separator(), at: 6)
        let version = Self.versionItem(Self.versionLine(version: versionProvider(), updateStatus: updateStatusProvider()))
        menu.insertItem(version, at: 7)
        let quit = NSMenuItem(title: "Quit VoiceBar", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The notch History list holds 20 (2.4 Lane A); the right-click submenu stays the eight it always showed.
    public static let recentTranscriptsMenuLimit = 8

    public func makeRecentTranscriptsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let entries = Array(recentTranscriptionEntriesProvider().prefix(Self.recentTranscriptsMenuLimit))

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
            item.toolTip = entry.text
            let title = NSMutableAttributedString(string: item.title, attributes: [
                .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            ])
            if let time = VoiceBarRelativeTime.label(entry.createdAt, now: now) {
                title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                   range: NSRange(location: 0, length: (time as NSString).length))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }

        return menu
    }

    /// Read-only (D2): the priority default, then "Change…". Picking a device here used to write the macOS default
    /// directly, and the priority list then put its own top device back.
    public func makeMicrophoneSubmenu() -> NSMenu {
        let menu = NSMenu()
        let current = NSMenuItem(
            title: Self.fittedMenuText(MicrophoneDefaultPresentation.title(defaultMicrophoneNameProvider()), middle: true),
            action: nil,
            keyEquivalent: ""
        )
        current.isEnabled = false
        current.toolTip = defaultMicrophoneNameProvider()
        menu.addItem(current)
        menu.addItem(.separator())
        let change = NSMenuItem(
            title: MicrophoneDefaultPresentation.changeTitle,
            action: #selector(handleChangeMicrophone),
            keyEquivalent: ""
        )
        change.target = self
        change.toolTip = MicrophoneDefaultPresentation.changeAccessibilityLabel
        change.setAccessibilityLabel(MicrophoneDefaultPresentation.changeAccessibilityLabel)
        menu.addItem(change)
        return menu
    }

    /// 2.3 U2 (3-wings mock): the chevron's microphone list, opening on the left beside the mic. It is a display
    /// of the priority list (D2, PLAN-2.3 U2 "a display-only change of the mic list"): the check marks the
    /// microphone the next dictation uses, and choosing any row or "Microphone priority…" opens Settings ›
    /// General › Microphone priority, where `MicrophonePriorityApplyCoordinator` stays the only writer.
    public func makeMicrophonePickerMenu() -> NSMenu {
        let menu = NSMenu(title: "Microphone")
        menu.autoenablesItems = false
        let header: NSMenuItem
        if #available(macOS 14.0, *) {
            header = NSMenuItem.sectionHeader(title: "Microphone")
        } else {
            header = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
            header.isEnabled = false
        }
        menu.addItem(header)
        let rows = microphonePickerRowsProvider()
        if rows.isEmpty {
            let none = NSMenuItem(title: "No microphones", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for row in rows {
            let rowItem = item(row.label, #selector(handleChangeMicrophone))
            rowItem.state = row.isNextDictation ? .on : .off
            rowItem.toolTip = MicrophoneDefaultPresentation.changeAccessibilityLabel
            menu.addItem(rowItem)
        }
        menu.addItem(.separator())
        let priority = item("Microphone priority…", #selector(handleChangeMicrophone))
        priority.setAccessibilityLabel(MicrophoneDefaultPresentation.changeAccessibilityLabel)
        menu.addItem(priority)
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = .command }
        menuItem.target = self
        return menuItem
    }

    public static func isPasteEnabled(transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Spec §3: time + the first words; no "Latest —".
    public static func recentTranscriptMenuTitle(for transcript: String, time: String?) -> String {
        let text = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let prefix = time.map { "\($0) · " } ?? ""
        return prefix + fittedMenuText(text, maximumWidth: max(0, 420 - textWidth(prefix)))
    }

    private static func textWidth(_ text: String, fontSize: CGFloat = 13) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: fontSize)]).width
    }

    /// Measure in the native menu font, preserving graphemes and an explicit ellipsis at every cut.
    private static func fittedMenuText(
        _ text: String, fontSize: CGFloat = 13, maximumWidth: CGFloat = 420, middle: Bool = false
    ) -> String {
        guard textWidth(text, fontSize: fontSize) > maximumWidth else { return text }
        let characters = Array(text)
        func candidate(_ count: Int) -> String {
            if middle {
                return String(characters.prefix((count + 1) / 2)) + "…" + String(characters.suffix(count / 2))
            }
            return String(characters.prefix(count)) + "…"
        }
        var low = 0
        var high = characters.count
        while low < high {
            let count = (low + high + 1) / 2
            if textWidth(candidate(count), fontSize: fontSize) <= maximumWidth { low = count }
            else { high = count - 1 }
        }
        if !middle {
            let prefix = String(characters.prefix(low))
            if let space = prefix.lastIndex(of: " ") {
                return String(prefix[..<space]) + "…"
            }
        }
        return candidate(low)
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

    @objc private func handleRetranscribeLatest() {
        guard canRetranscribeLatestProvider() else { return }
        onRetranscribeLatest()
    }

    @objc private func handleCopyLastTranscript() {
        onCopyLastTranscript()
    }

    @objc private func handlePasteRecentTranscript(_ sender: NSMenuItem) {
        guard let transcript = sender.representedObject as? String else { return }
        onPasteTranscript(transcript)
    }

    @objc private func handleChangeMicrophone() {
        onChangeMicrophone()
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

/// 2.3 U2: one row of the notch microphone list.
public struct MicrophonePickerRow: Equatable {
    public let label: String
    public let isNextDictation: Bool

    public init(label: String, isNextDictation: Bool) {
        self.label = label
        self.isNextDictation = isNextDictation
    }

    /// Connected, visible priority rows in priority order; the check follows the snapshot's next device.
    public static func rows(from snapshot: MicrophonePrioritySnapshot) -> [MicrophonePickerRow] {
        snapshot.visibleRows.filter(\.isConnected).map { row in
            let isNext: Bool = if let uid = row.uid, let nextUID = snapshot.nextDeviceUID {
                uid == nextUID
            } else if let id = row.deviceID, let nextID = snapshot.nextDeviceID {
                id == nextID
            } else {
                false
            }
            return MicrophonePickerRow(label: row.label, isNextDictation: isNext)
        }
    }
}

/// Etan's D2 (2026-09-25): every surface shows the microphone-priority default read-only; "Change…" leads to
/// Settings › Microphone priority, the one place the default is chosen.
public enum MicrophoneDefaultPresentation {
    public static func title(_ name: String?) -> String {
        "Default: \(name ?? "Unavailable")"
    }

    public static func accessibilityLabel(_ name: String?) -> String {
        "Default microphone: \(name ?? "unavailable")"
    }

    public static let changeTitle = "Change…"
    public static let changeAccessibilityLabel = "Change default microphone in Settings"
}
