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

    func testMenuIncludesVocabularySubmenuBetweenHistoryAndPaste() throws {
        let controller = PillContextMenuController()
        controller.anchorModeProvider = { .topCenter }
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
            "Transcribe latest recording",
            "Add to Dictionary…",
            "Transcription Vocabulary",
            "Anchor",
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

        let anchorItem = try XCTUnwrap(menu.items.first { $0.title == "Anchor" })
        let anchorSubmenu = try XCTUnwrap(anchorItem.submenu)
        XCTAssertEqual(anchorSubmenu.items.map(\.title), [
            "Off",
            "Top Center",
            "Bottom Center",
        ])
        XCTAssertEqual(anchorSubmenu.items[1].state, .on)
        XCTAssertFalse(anchorSubmenu.items.map(\.title).contains("Lock Position"))
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

    func testMenuIncludesSettingsHistoryAndCopyActions() throws {
        let controller = PillContextMenuController()
        controller.anchorModeProvider = { .follow }
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
            "Transcribe latest recording",
            "Add to Dictionary…",
            "Transcription Vocabulary",
            "Anchor",
            "Microphone",
            "Paste last transcript",
            "Copy last transcript",
            "",
            "Quit VoiceBar",
        ])

        let recoverItem = try XCTUnwrap(menu.items.first { $0.title == "Transcribe latest recording" })
        XCTAssertTrue(recoverItem.isEnabled)

        let submenuTitles = menu.items[2].submenu?.items.map(\.title)
        XCTAssertEqual(submenuTitles, [
            "Latest — latest note",
            "older note with new lines flattened",
        ])

        let vocabularyTitles = menu.items[5].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyTitles, [
            "Terms",
            "Corrections",
        ])

        let vocabularyTerms = menu.items[5].submenu?.items[0].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyTerms, [
            "VoiceLayer",
            "orcClaude",
            "Wispr Flow",
        ])

        let vocabularyCorrections = menu.items[5].submenu?.items[1].submenu?.items.map(\.title)
        XCTAssertEqual(vocabularyCorrections, [
            "work claude → orcClaude",
            "whisper flow → Wispr Flow",
        ])

        let anchorTitles = menu.items[6].submenu?.items.map(\.title)
        XCTAssertEqual(anchorTitles, [
            "Off",
            "Top Center",
            "Bottom Center",
        ])
        XCTAssertEqual(menu.items[6].submenu?.items[0].state, .on)
    }

    func testAnchorSubmenuActionsCallOnlyAnchorSelectionHandlers() throws {
        let controller = PillContextMenuController()
        controller.anchorModeProvider = { .follow }
        var selectedModes: [VoiceBarAnchorMode] = []
        controller.onSelectAnchorMode = { selectedModes.append($0) }

        let anchorItem = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Anchor" })
        let submenu = try XCTUnwrap(anchorItem.submenu)
        let topCenter = try XCTUnwrap(submenu.items.first { $0.title == "Top Center" })

        _ = topCenter.target?.perform(topCenter.action, with: topCenter)

        XCTAssertEqual(selectedModes, [.topCenter])
        XCTAssertNil(submenu.items.first { $0.title == "Lock Position" })
    }

    func testAnchorSubmenuHasExactlyOneCheckedStateForEachMode() throws {
        for mode in VoiceBarAnchorMode.anchorMenuModes {
            let controller = PillContextMenuController()
            controller.anchorModeProvider = { mode }

            let anchorItem = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Anchor" })
            let submenu = try XCTUnwrap(anchorItem.submenu)
            let checkedItems = submenu.items.filter { $0.state == .on }

            XCTAssertEqual(submenu.items.map(\.title), [
                "Off",
                "Top Center",
                "Bottom Center",
            ])
            XCTAssertEqual(checkedItems.map(\.title), [mode.anchorMenuTitle])
        }
    }

    func testTranscribeLatestRecordingActionCallsHandler() throws {
        let controller = PillContextMenuController()
        var tapped = false
        controller.onTranscribeLatestRecording = {
            tapped = true
        }

        let menu = controller.makeMenu()
        let recoverItem = try XCTUnwrap(menu.items.first { $0.title == "Transcribe latest recording" })

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
        let addItem = try XCTUnwrap(menu.items.first { $0.title == "Add to Dictionary…" })

        _ = addItem.target?.perform(addItem.action, with: addItem)

        XCTAssertTrue(tapped)
    }
}
