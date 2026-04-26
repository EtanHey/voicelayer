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
            "Retranscribe Last Capture",
            "Vocabulary",
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

    func testMenuIncludesVocabularySubmenuBetweenHistoryAndPaste() throws {
        let controller = PillContextMenuController()
        controller.transcriptionVocabularyTermsProvider = {
            ["VoiceLayer", "Wispr Flow"]
        }
        controller.transcriptionVocabularyAliasesProvider = {
            [STTVocabularyAliasPreview(from: "work claude", to: "orcClaude")]
        }

        let menu = controller.makeMenu()
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles, [
            "Hide for 1 hour",
            "Microphone",
            "Transcript History",
            "Retranscribe Last Capture",
            "Vocabulary",
            "Paste last transcript",
            "",
            "Quit VoiceBar",
        ])

        let vocabularyItem = try XCTUnwrap(menu.items.first { $0.title == "Vocabulary" })
        let submenu = try XCTUnwrap(vocabularyItem.submenu)
        XCTAssertEqual(submenu.items.map(\.title), [
            "Terms",
            "Corrections",
        ])

        let terms = submenu.items[0].submenu?.items.map(\.title)
        XCTAssertEqual(terms, ["VoiceLayer", "Wispr Flow"])

        let corrections = submenu.items[1].submenu?.items.map(\.title)
        XCTAssertEqual(corrections, ["work claude → orcClaude"])
    }

    func testVocabularySubmenuShowsEmptyStateWhenSnapshotHasNoTermsOrCorrections() throws {
        let controller = PillContextMenuController()
        controller.transcriptionVocabularyTermsProvider = { [] }
        controller.transcriptionVocabularyAliasesProvider = { [] }

        let menu = controller.makeMenu()
        let vocabularyItem = try XCTUnwrap(menu.items.first { $0.title == "Vocabulary" })
        let submenu = try XCTUnwrap(vocabularyItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), ["Vocabulary not loaded yet"])
        XCTAssertFalse(submenu.items[0].isEnabled)
    }

    func testMenuIncludesRetranscribeActionBetweenHistoryAndVocabulary() throws {
        let controller = PillContextMenuController()
        controller.hasRetranscribableCaptureProvider = { true }

        let menu = controller.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), [
            "Hide for 1 hour",
            "Microphone",
            "Transcript History",
            "Retranscribe Last Capture",
            "Vocabulary",
            "Paste last transcript",
            "",
            "Quit VoiceBar",
        ])

        let item = try XCTUnwrap(menu.items.first { $0.title == "Retranscribe Last Capture" })
        XCTAssertTrue(item.isEnabled)
    }

    func testRetranscribeActionStaysVisibleButDisabledWithoutRetainedCapture() throws {
        let controller = PillContextMenuController()
        controller.hasRetranscribableCaptureProvider = { false }

        let menu = controller.makeMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Retranscribe Last Capture" })

        XCTAssertFalse(item.isEnabled)
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
