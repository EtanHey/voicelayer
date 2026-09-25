import AppKit
@testable import VoiceBarUI
import XCTest

final class PillContextMenuControllerTests: XCTestCase {
    func testHistorySubmenuShowsEmptyStateWhenNoRecentTranscriptionsExist() throws {
        let controller = PillContextMenuController()
        controller.recentTranscriptionEntriesProvider = { [] }

        let menu = controller.makeMenu()
        let historyItem = try XCTUnwrap(menu.items.first { $0.title == "Recent Transcriptions" })
        let submenu = try XCTUnwrap(historyItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), ["No recent transcripts"])
        XCTAssertFalse(submenu.items[0].isEnabled)
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// Etan's approved spec §3 (p03-design-spec-approval/spec.md), item for item.
    func testMenuMatchesTheApprovedSpecExactly() throws {
        let controller = PillContextMenuController()
        let menu = controller.makeMenu()

        XCTAssertEqual(titles(menu), [
            "Settings…",
            "Hide for 1 hour",
            "—",
            "Recent Transcriptions",
            "Paste Last Transcript",
            "Copy Last Transcript",
            "—",
            "Microphone",
            "—",
            "Quit VoiceBar",
        ])
        let settings = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertNotNil(settings.image, "Settings… carries the gearshape symbol")
        XCTAssertNotNil(menu.items.first { $0.title == "Recent Transcriptions" }?.submenu)
        XCTAssertNotNil(menu.items.first { $0.title == "Microphone" }?.submenu)
    }

    func testSnoozedMenuSwapsOnlyTheHideItem() {
        let controller = PillContextMenuController()
        controller.isSnoozedProvider = { true }
        XCTAssertEqual(titles(controller.makeMenu())[1], "Show VoiceBar")
    }

    /// Spec §3 removes Transcription Tools (Transcribe latest, Add to Dictionary, the vocabulary wall),
    /// Anchor and Morph Prototype. Add to Dictionary lives in Settings → Dictionary.
    func testMenuTreeCarriesNoRemovedItems() {
        func all(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(all) ?? []) }
        }
        let every = all(PillContextMenuController().makeMenu())
        for removed in ["Transcription Tools", "Transcribe latest", "Add to Dictionary", "Open Dictionary",
                        "Vocabulary", "Anchor", "Morph", "Preferences", "Latest —"] {
            XCTAssertFalse(every.contains { $0.contains(removed) }, "\(removed) is back: \(every)")
        }
    }

    func testRecentItemsShowTimeAndFirstWordsWithoutLatestDash() throws {
        let controller = PillContextMenuController()
        controller.now = { self.now }
        controller.recentTranscriptionEntriesProvider = {
            [
                RecentTranscriptionEntry(text: "latest note", createdAt: self.now.addingTimeInterval(-120)),
                RecentTranscriptionEntry(
                    text: "older note with\nnew lines flattened",
                    createdAt: self.now.addingTimeInterval(-7200)
                ),
                RecentTranscriptionEntry(text: "saved before times existed"),
            ]
        }

        let submenu = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Recent Transcriptions" }?.submenu)

        XCTAssertEqual(submenu.items.map(\.title), [
            "2 min ago · latest note",
            "2 hr ago · older note with new lines flattened",
            "saved before times existed",
        ])
        XCTAssertFalse(submenu.items.contains { $0.title.contains("—") })
    }

    func testRecentItemPastesThatTranscript() throws {
        let controller = PillContextMenuController()
        var pasted: [String] = []
        controller.onPasteTranscript = { pasted.append($0) }
        controller.recentTranscriptionEntriesProvider = { [RecentTranscriptionEntry(text: "paste me")] }
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Recent Transcriptions" }?.submenu?
            .items.first)
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(pasted, ["paste me"])
    }

    func testQuitCallsHandler() throws {
        let controller = PillContextMenuController()
        var quits = 0
        controller.onQuit = { quits += 1 }
        let quit = try XCTUnwrap(controller.makeMenu().items.last)
        _ = quit.target?.perform(quit.action, with: quit)
        XCTAssertEqual(quits, 1)
    }

    func testMicrophoneItemShowsTheCurrentDevice() throws {
        let controller = PillContextMenuController()
        controller.availableDevicesProvider = {
            [MicrophoneDevice(id: "a", name: "MacBook Pro Microphone"), MicrophoneDevice(id: "b", name: "USB Mic")]
        }
        controller.selectedDeviceIDProvider = { "b" }
        let microphone = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Microphone" })
        if #available(macOS 14.4, *) {
            XCTAssertEqual(microphone.subtitle, "USB Mic")
        }
        XCTAssertEqual(microphone.submenu?.items.filter { $0.state == .on }.map(\.title), ["USB Mic"])
    }

    func testDeviceOptionsMarkSelectedMicrophone() {
        let options = PillContextMenuController.deviceOptions(
            devices: [
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                MicrophoneDevice(id: "usb", name: "USB Mic"),
            ],
            selectedID: "usb"
        )

        XCTAssertEqual(options.map(\.title), [
            "MacBook Pro Microphone",
            "USB Mic",
        ])
        XCTAssertEqual(options.map(\.isSelected), [false, true])
    }

    func testPasteActionEnabledOnlyWhenTranscriptExists() {
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: ""))
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: "   "))
        XCTAssertTrue(PillContextMenuController.isPasteEnabled(transcript: "latest note"))
    }
}
