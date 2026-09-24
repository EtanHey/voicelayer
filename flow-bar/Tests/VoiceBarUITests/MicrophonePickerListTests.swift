@testable import VoiceBarUI
import XCTest

/// R4 UI pass finding #2: the menu-bar popover and the right-click Microphone submenu listed VoiceBar's own
/// `CADefaultDeviceAggregate-<pid>-0`, "Microsoft Teams Audio" and "ZoomAudioDevice", while Settings'
/// priority list showed only the real mics. Every picker now draws from ONE filtered list.
final class MicrophonePickerListTests: XCTestCase {
    /// The live 2.2.24 device set, shaped as CoreAudio reports it (29434 was VoiceBar's own pid).
    private let liveShaped: [MicrophoneDevice] = [
        MicrophoneDevice(id: "71", name: "CADefaultDeviceAggregate-29434-0",
                         uid: "CADefaultDeviceAggregate-29434-0", isVirtualOrAggregateTransport: true),
        MicrophoneDevice(id: "88", name: "AirPods", uid: "airpods-uid", isVirtualOrAggregateTransport: false),
        MicrophoneDevice(id: "90", name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice",
                         isVirtualOrAggregateTransport: false),
        MicrophoneDevice(id: "95", name: "Microsoft Teams Audio", uid: "MSTeamsAudioDevice_UID",
                         isVirtualOrAggregateTransport: true),
        MicrophoneDevice(id: "97", name: "Wireless Mic Rx", uid: "rx-uid", isVirtualOrAggregateTransport: false),
        MicrophoneDevice(id: "99", name: "ZoomAudioDevice", uid: "zoom.us.zoomaudiodevice.001",
                         isVirtualOrAggregateTransport: true),
    ]
    private let realMics = ["AirPods", "MacBook Pro Microphone", "Wireless Mic Rx"]

    func testRightClickSubmenuListsOnlyRealMicrophones() {
        let options = PillContextMenuController.deviceOptions(devices: liveShaped, selectedID: "90")

        XCTAssertEqual(options.map(\.title), realMics)
        XCTAssertEqual(options.filter(\.isSelected).map(\.title), ["MacBook Pro Microphone"])
    }

    func testMenuBarPopoverListsOnlyRealMicrophones() {
        let popover = MenuBarPopoverView(
            footer: .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                             remoteSTTConfigured: false, hasFreshHealth: true),
            hotkeyHint: "Hold F5 to dictate",
            microphoneName: "MacBook Pro Microphone",
            microphones: liveShaped,
            selectedMicrophoneID: "90",
            transcript: ""
        )

        XCTAssertEqual(popover.microphones.map(\.name), realMics)
    }

    func testEveryPickerMatchesTheSettingsPriorityList() throws {
        let suiteName = "r4-g1-one-mic-list-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let priority = MicrophoneDevicePriority(defaults: defaults)
        priority.observe(liveShaped)
        let settings = MicrophonePrioritySnapshot(rows: priority.rows(for: liveShaped), nextDeviceName: nil)

        XCTAssertEqual(Set(settings.visibleRows.map(\.label)), Set(realMics))
        XCTAssertEqual(Set(MicrophoneDevice.pickable(liveShaped).map(\.name)), Set(realMics))
    }

    /// Without a transport type (the CoreAudio read failed), identity is the fallback, so the aggregate and the
    /// Teams/Zoom loopbacks still never reach a picker.
    func testUnknownTransportFallsBackToTheDeviceIdentity() {
        let unknownTransport = liveShaped.map {
            MicrophoneDevice(id: $0.id, name: $0.name, uid: $0.uid, isVirtualOrAggregateTransport: nil)
        }

        XCTAssertEqual(MicrophoneDevice.pickable(unknownTransport).map(\.name), realMics)
    }

    func testTransportTypeStillWinsOverAVirtualSoundingName() {
        let physical = MicrophoneDevice(id: "5", name: "Virtual Studio Mic", uid: "studio",
                                        isVirtualOrAggregateTransport: false)

        XCTAssertEqual(MicrophoneDevice.pickable([physical]).map(\.name), ["Virtual Studio Mic"])
    }
}

/// #141 review MUST-FIX 1: when the device actually in use is a hidden one (Teams, Zoom, VoiceBar's own
/// aggregate), every picker still says so: a checked, disabled, clearly marked row on top, and every real mic
/// stays selectable. Never a list with nothing checked.
final class MicrophonePickerHiddenSelectionTests: XCTestCase {
    private let devices: [MicrophoneDevice] = [
        MicrophoneDevice(id: "88", name: "AirPods", uid: "airpods-uid", isVirtualOrAggregateTransport: false),
        MicrophoneDevice(id: "95", name: "Microsoft Teams Audio", uid: "MSTeamsAudioDevice_UID",
                         isVirtualOrAggregateTransport: true),
        MicrophoneDevice(id: "97", name: "Wireless Mic Rx", uid: "rx-uid", isVirtualOrAggregateTransport: false),
    ]

    func testRightClickShowsTheHiddenDeviceInUseCheckedAndDisabledOnTop() {
        let options = PillContextMenuController.deviceOptions(devices: devices, selectedID: "95")

        XCTAssertEqual(options.map(\.title), [
            "In use: Microsoft Teams Audio (hidden device)", "AirPods", "Wireless Mic Rx",
        ])
        XCTAssertEqual(options.map(\.isSelected), [true, false, false])
        XCTAssertEqual(options.map(\.isEnabled), [false, true, true])
    }

    func testRightClickSubmenuSeparatesTheHiddenRowFromTheRealMics() {
        let controller = PillContextMenuController()
        controller.availableDevicesProvider = { self.devices }
        controller.selectedDeviceIDProvider = { "95" }
        let menu = controller.makeMicrophoneSubmenu()

        XCTAssertEqual(menu.items.first?.title, "In use: Microsoft Teams Audio (hidden device)")
        XCTAssertEqual(menu.items.first?.state, .on)
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertTrue(menu.items.dropFirst().first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.dropFirst(2).map(\.title), ["AirPods", "Wireless Mic Rx"])
    }

    func testPopoverKeepsTheHiddenDeviceInUseAndListsOnlyRealMics() {
        let popover = MenuBarPopoverView(
            footer: .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                             remoteSTTConfigured: false, hasFreshHealth: true),
            hotkeyHint: "Hold F5 to dictate",
            microphoneName: "Microsoft Teams Audio",
            microphones: devices,
            selectedMicrophoneID: "95",
            transcript: ""
        )

        XCTAssertEqual(popover.hiddenInUseMicrophone?.name, "Microsoft Teams Audio")
        XCTAssertEqual(popover.microphones.map(\.name), ["AirPods", "Wireless Mic Rx"])
    }

    func testSettingsNamesTheHiddenDeviceInUse() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "rx-uid", deviceID: "97", label: "Wireless Mic Rx", isConnected: true,
                  isVirtualOrAggregateTransport: false),
            .init(uid: "MSTeamsAudioDevice_UID", deviceID: "95", label: "Microsoft Teams Audio", isConnected: true,
                  isVirtualOrAggregateTransport: true),
        ], nextDeviceName: "Microsoft Teams Audio", nextDeviceUID: "MSTeamsAudioDevice_UID", nextDeviceID: "95")

        XCTAssertEqual(snapshot.nextVisibleDeviceName, "Microsoft Teams Audio (hidden device)")
    }

    func testNoHiddenRowWhenARealMicIsInUse() {
        let options = PillContextMenuController.deviceOptions(devices: devices, selectedID: "97")

        XCTAssertEqual(options.map(\.title), ["AirPods", "Wireless Mic Rx"])
        XCTAssertEqual(options.map(\.isSelected), [false, true])
    }
}
