import AppKit
@testable import VoiceBarUI
import XCTest

final class PillContextMenuControllerTests: XCTestCase {
    func testHistorySubmenuShowsEmptyStateWhenNoRecentTranscriptionsExist() throws {
        let controller = PillContextMenuController()
        controller.recentTranscriptionsProvider = { [] }

        let menu = controller.makeMenu()
        let historyItem = try XCTUnwrap(menu.items.first { $0.title == "Recent Transcripts" })
        let submenu = try XCTUnwrap(historyItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), ["No recent transcripts"])
        XCTAssertFalse(submenu.items[0].isEnabled)
    }

    func testMenuGroupsSecondaryActionsIntoSubmenus() throws {
        let menu = PillContextMenuController().makeMenu()

        XCTAssertEqual(menu.items.map(\.title), [
            "Settings",
            "Hide for 1 hour",
            "Recent Transcripts",
            "Paste last transcript",
            "Copy last transcript",
            "Transcription Tools",
            "Microphone",
        ])

        let toolsSubmenu = try XCTUnwrap(menu.items.first { $0.title == "Transcription Tools" }?.submenu)
        XCTAssertEqual(toolsSubmenu.items.map(\.title), [
            "Transcribe latest recording",
            "Add to Dictionary…",
            "Open Dictionary…",
        ])
        XCTAssertNil(toolsSubmenu.items.first { $0.title == "Open Dictionary…" }?.submenu)

        XCTAssertNotNil(menu.items.first { $0.title == "Microphone" }?.submenu)
    }

    /// R4 UI pass #4/#5 and Etan ruling 1: no prototype switch, no Anchor, no wall of disabled vocabulary.
    func testMenuTreeCarriesNoDeveloperLeftovers() {
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        let all = titles(PillContextMenuController().makeMenu())

        for leftover in ["Anchor", "Morph", "Prototype", "Transcription Vocabulary", "Terms", "Corrections",
                         "Top Center", "Bottom Center", "Preferences"] {
            XCTAssertFalse(all.contains { $0.contains(leftover) }, "menu still carries \(leftover): \(all)")
        }
    }

    func testOpenDictionaryCallsHandler() throws {
        let controller = PillContextMenuController()
        var opened = 0
        controller.onOpenDictionary = { opened += 1 }

        let tools = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Transcription Tools" }?.submenu)
        let item = try XCTUnwrap(tools.items.first { $0.title == "Open Dictionary…" })
        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(opened, 1)
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

    func testMenuIncludesSettingsHistoryCopyAndGroupedTools() throws {
        let controller = PillContextMenuController()
        controller.transcriptProvider = { "latest note" }
        controller.recentTranscriptionsProvider = {
            [
                "latest note",
                "older note with\nnew lines flattened",
            ]
        }

        let menu = controller.makeMenu()

        let toolsSubmenu = try XCTUnwrap(menu.items.first { $0.title == "Transcription Tools" }?.submenu)
        let recoverItem = try XCTUnwrap(toolsSubmenu.items.first { $0.title == "Transcribe latest recording" })
        XCTAssertTrue(recoverItem.isEnabled)

        let submenuTitles = menu.items[2].submenu?.items.map(\.title)
        XCTAssertEqual(submenuTitles, [
            "Latest — latest note",
            "older note with new lines flattened",
        ])
    }

    func testTranscribeLatestRecordingActionCallsHandler() throws {
        let controller = PillContextMenuController()
        var tapped = false
        controller.onTranscribeLatestRecording = {
            tapped = true
        }

        let menu = controller.makeMenu()
        let toolsItem = try XCTUnwrap(menu.items.first { $0.title == "Transcription Tools" })
        let recoverItem = try XCTUnwrap(toolsItem.submenu?.items.first { $0.title == "Transcribe latest recording" })

        _ = recoverItem.target?.perform(recoverItem.action, with: recoverItem)

        XCTAssertTrue(tapped)
    }

    func testAddToDictionaryActionCallsHandler() throws {
        let controller = PillContextMenuController()
        var tapped = false
        controller.onAddSelectionToDictionary = {
            tapped = true
        }

        let menu = controller.makeMenu()
        let toolsItem = try XCTUnwrap(menu.items.first { $0.title == "Transcription Tools" })
        let addItem = try XCTUnwrap(toolsItem.submenu?.items.first { $0.title == "Add to Dictionary…" })

        _ = addItem.target?.perform(addItem.action, with: addItem)

        XCTAssertTrue(tapped)
    }
}
