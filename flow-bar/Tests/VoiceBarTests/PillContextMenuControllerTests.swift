@testable import VoiceBar
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
            "Settings",
            "Hide for 1 hour",
            "Recent Transcripts",
            "Transcription Vocabulary",
            "Microphone",
            "Paste last transcript",
            "Copy last transcript",
            "",
            "Quit VoiceBar",
        ])

        let vocabularyItem = try XCTUnwrap(menu.items.first { $0.title == "Transcription Vocabulary" })
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
        let vocabularyItem = try XCTUnwrap(menu.items.first { $0.title == "Transcription Vocabulary" })
        let submenu = try XCTUnwrap(vocabularyItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), ["Vocabulary not loaded yet"])
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

    func testMenuIncludesSettingsHistoryAndCopyActions() {
        let controller = PillContextMenuController()
        controller.transcriptProvider = { "latest note" }
        controller.recentTranscriptionsProvider = {
            [
                "latest note",
                "older note with\nnew lines flattened",
            ]
        }
        controller.transcriptionVocabularyTermsProvider = {
            ["VoiceLayer", "orcClaude", "Wispr Flow"]
        }
        controller.transcriptionVocabularyAliasesProvider = {
            [
                STTVocabularyAliasPreview(from: "work claude", to: "orcClaude"),
                STTVocabularyAliasPreview(from: "whisper flow", to: "Wispr Flow"),
            ]
        }

        let menu = controller.makeMenu()

        XCTAssertEqual(menu.items.map(\.title), [
            "Settings",
            "Hide for 1 hour",
            "Recent Transcripts",
            "Transcription Vocabulary",
            "Microphone",
            "Paste last transcript",
            "Copy last transcript",
            "",
            "Quit VoiceBar",
        ])

        let submenuTitles = menu.items[2].submenu?.items.map(\.title)
        XCTAssertEqual(submenuTitles, [
            "Latest — latest note",
            "older note with new lines flattened",
        ])

        let vocabularyTitles = menu.items[3].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyTitles, [
            "Terms",
            "Corrections",
        ])

        let vocabularyTerms = menu.items[3].submenu?.items[0].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyTerms, [
            "VoiceLayer",
            "orcClaude",
            "Wispr Flow",
        ])

        let vocabularyCorrections = menu.items[3].submenu?.items[1].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyCorrections, [
            "work claude → orcClaude",
            "whisper flow → Wispr Flow",
        ])
    }
}
