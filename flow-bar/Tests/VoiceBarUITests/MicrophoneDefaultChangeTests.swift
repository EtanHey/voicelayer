@testable import VoiceBarUI
import XCTest

/// QA 2.2.25 C17/C21 + Etan's D2 (2026-09-25): picking a microphone must never silently change anything. The
/// pickers wrote the macOS default input directly while the priority list re-applied its own top device, so a
/// pick "worked for a moment, then went back". Every surface now shows the priority's default read-only, with
/// "Change…" leading to Settings › Microphone priority, where the default is chosen.
final class MicrophoneDefaultChangeTests: XCTestCase {
    func testTheRightClickMicrophoneSubmenuIsReadOnlyWithChange() throws {
        let controller = PillContextMenuController()
        controller.defaultMicrophoneNameProvider = { "Wireless Mic Rx" }
        var changes = 0
        controller.onChangeMicrophone = { changes += 1 }

        let microphone = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Microphone" })
        if #available(macOS 14.4, *) {
            XCTAssertEqual(microphone.subtitle, "Wireless Mic Rx")
        }
        let items = try XCTUnwrap(microphone.submenu?.items)
        XCTAssertEqual(items.map { $0.isSeparatorItem ? "—" : $0.title }, ["Default: Wireless Mic Rx", "—", "Change…"])
        XCTAssertFalse(items[0].isEnabled, "the default row is read-only")
        XCTAssertNil(items[0].action)

        let change = items[2]
        XCTAssertTrue(change.isEnabled)
        XCTAssertEqual(change.accessibilityLabel(), "Change default microphone in Settings",
                       "VoiceOver hears what Change… does, not just its title")
        _ = change.target?.perform(change.action, with: change)
        XCTAssertEqual(changes, 1)
    }

    func testTheSubmenuSaysWhenNoDefaultIsKnown() throws {
        let controller = PillContextMenuController()
        controller.defaultMicrophoneNameProvider = { nil }

        let items = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Microphone" }?.submenu?.items)
        XCTAssertEqual(items.first?.title, "Default: Unavailable")
    }

    func testThePopoverShowsTheDefaultReadOnlyWithChange() {
        var changes = 0
        let popover = MenuBarPopoverView(
            footer: .resolve(isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
                             remoteSTTConfigured: false, hasFreshHealth: true),
            hotkeyHint: "Hold F5 to dictate",
            defaultMicrophoneName: "Wireless Mic Rx",
            transcript: "",
            onChangeMicrophone: { changes += 1 }
        )

        XCTAssertEqual(popover.defaultMicrophoneTitle, "Default: Wireless Mic Rx")
        XCTAssertEqual(popover.defaultMicrophoneAccessibilityLabel, "Default microphone: Wireless Mic Rx")
        popover.onChangeMicrophone()
        XCTAssertEqual(changes, 1)
    }

    /// The name every surface shows is the one Settings shows as "Next dictation", including the hidden-device
    /// label from #141, so a hidden device in use is never presented as a normal choice.
    func testTheDefaultNameIsThePrioritySnapshotsNextDevice() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            .init(uid: "MSTeamsAudioDevice_UID", deviceID: "95", label: "Microsoft Teams Audio", isConnected: true,
                  isVirtualOrAggregateTransport: true),
        ], nextDeviceName: "Microsoft Teams Audio", nextDeviceUID: "MSTeamsAudioDevice_UID", nextDeviceID: "95")

        XCTAssertEqual(MicrophoneDefaultPresentation.title(snapshot.nextVisibleDeviceName),
                       "Default: Microsoft Teams Audio (hidden device)")
    }

    func testAMicrophonePriorityRequestOpensGeneralFocusedOnThePriorityList() {
        let request = SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1)

        XCTAssertEqual(request.tab, .general)
        XCTAssertEqual(request.focus, .microphonePriority)
        XCTAssertEqual(SettingsTabRequest(tab: .dictionary, id: 2).focus, nil)
    }
}
