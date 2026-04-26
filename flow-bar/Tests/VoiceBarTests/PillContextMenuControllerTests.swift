@testable import VoiceBar
import XCTest

final class PillContextMenuControllerTests: XCTestCase {
    func testMenuIncludesTranscriptHistorySubmenuAheadOfPasteAction() throws {
        let controller = PillContextMenuController()
        controller.recentTranscriptionsProvider = {
            ["latest transcript", "earlier transcript"]
        }

        let menu = controller.makeMenu()
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles, [
            "Hide for 1 hour",
            "Microphone",
            "Transcript History",
            "Paste last transcript",
            "",
            "Quit VoiceBar",
        ])

        let historyItem = try XCTUnwrap(menu.items.first { $0.title == "Transcript History" })
        let submenu = try XCTUnwrap(historyItem.submenu)
        XCTAssertEqual(submenu.items.map(\.title), [
            "Latest",
            "latest transcript",
            "earlier transcript",
        ])
        XCTAssertFalse(submenu.items[1].isEnabled)
        XCTAssertFalse(submenu.items[2].isEnabled)
    }

    func testHistorySubmenuShowsEmptyStateWhenNoRecentTranscriptionsExist() throws {
        let controller = PillContextMenuController()
        controller.recentTranscriptionsProvider = { [] }

        let menu = controller.makeMenu()
        let historyItem = try XCTUnwrap(menu.items.first { $0.title == "Transcript History" })
        let submenu = try XCTUnwrap(historyItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), ["No recent transcriptions yet"])
        XCTAssertFalse(submenu.items[0].isEnabled)
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
