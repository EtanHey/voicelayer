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

    func testRecentTitlesUseMeasuredWidthAndWholeWords() {
        let source = "A short opening followed by " + String(repeating: "extraordinarily readable words ", count: 12)
        let title = PillContextMenuController.recentTranscriptMenuTitle(for: source, time: "2 min ago")
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual((title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width, 420)
        let preview = String(title.dropFirst("2 min ago · ".count).dropLast())
        XCTAssertTrue(source.hasPrefix(preview + " "), "Truncate at a word boundary")
    }

    func testRecentTitlesNormalizeWhitespaceAndKeepUnicodeCharacters() {
        XCTAssertEqual(PillContextMenuController.recentTranscriptMenuTitle(
            for: "  hello\tthere\n  👩🏽‍💻 שלום  ", time: "2 min ago"), "2 min ago · hello there 👩🏽‍💻 שלום")
        for token in ["👨‍👩‍👧‍👦", "שָׁלוֹם", "👩🏽‍💻"] {
            let title = PillContextMenuController.recentTranscriptMenuTitle(
                for: String(repeating: token, count: 100), time: nil)
            XCTAssertTrue(title.hasSuffix("…"))
            XCTAssertEqual(String(title.dropLast()).replacingOccurrences(of: token, with: ""), "")
            XCTAssertLessThanOrEqual((title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width, 420)
        }
    }

    func testMicrophoneSubtitleHasRoomAndFullNameRemainsDiscoverable() throws {
        let name = "Studio microphone with a descriptive USB device name"
        let controller = PillContextMenuController()
        controller.defaultMicrophoneNameProvider = { name }
        let menu = controller.makeMenu()
        let microphone = try XCTUnwrap(menu.item(withTitle: "Microphone"))
        if #available(macOS 14.4, *) { XCTAssertEqual(microphone.subtitle, name) }
        XCTAssertEqual(microphone.toolTip, name)
        XCTAssertGreaterThanOrEqual(menu.minimumWidth,
            (name as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 11)]).width + 64)
        let longName = String(repeating: "Studio Microphone ", count: 20) + "USB"
        controller.defaultMicrophoneNameProvider = { longName }
        let longMenu = controller.makeMenu()
        let longMic = try XCTUnwrap(longMenu.item(withTitle: "Microphone"))
        if #available(macOS 14.4, *) {
            XCTAssertTrue(longMic.subtitle?.contains("…") == true)
            XCTAssertTrue(longMic.subtitle?.hasSuffix("USB") == true)
        }
        XCTAssertEqual(longMic.toolTip, longName)
        XCTAssertLessThanOrEqual(longMenu.minimumWidth, 484)
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
            "Re-transcribe latest",
            "—",
            "Microphone",
            "—",
            "Quit VoiceBar",
        ])
        let settings = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(settings.keyEquivalent, "")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertNotNil(settings.image, "Settings… carries the gearshape symbol")
        XCTAssertNotNil(menu.items.first { $0.title == "Recent Transcriptions" }?.submenu)
        XCTAssertNotNil(menu.items.first { $0.title == "Microphone" }?.submenu)
    }

    func testRetranscribeLatestInvokesCallbackOnceWithoutShortcut() throws {
        let controller = PillContextMenuController()
        controller.canRetranscribeLatestProvider = { true }
        var calls = 0
        controller.onRetranscribeLatest = { calls += 1 }
        let item = try XCTUnwrap(controller.makeMenu().item(withTitle: "Re-transcribe latest"))
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.keyEquivalent, "")
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(calls, 1)
    }

    func testRetranscribeLatestDisabledForEveryBusyStateAndMissingCapture() throws {
        let state = VoiceState()
        let controller = PillContextMenuController()
        var hasCapture = false
        controller.canRetranscribeLatestProvider = {
            state.canRetranscribeLatestCapture(hasLatestCapture: hasCapture)
        }
        func assertEnabled(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
            let menu = controller.makeMenu()
            menu.update()
            let item = try XCTUnwrap(menu.item(withTitle: "Re-transcribe latest"))
            XCTAssertEqual(item.isEnabled, expected, file: file, line: line)
        }
        state.mode = .idle
        try assertEnabled(false)
        hasCapture = true
        try assertEnabled(true)
        state.mode = .recording
        try assertEnabled(false)
        state.mode = .transcribing
        try assertEnabled(false)
        state.mode = .idle
        state.retranscribeHistoryEntry(recordingPath: "/test/capture.wav")
        try assertEnabled(false)

        let latestState = VoiceState()
        controller.canRetranscribeLatestProvider = {
            latestState.canRetranscribeLatestCapture(hasLatestCapture: true)
        }
        latestState.retranscribeLastCapture()
        try assertEnabled(false)
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

    func testMicrophoneItemShowsThePriorityDefault() throws {
        let controller = PillContextMenuController()
        controller.defaultMicrophoneNameProvider = { "USB Mic" }
        let microphone = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Microphone" })
        if #available(macOS 14.4, *) {
            XCTAssertEqual(microphone.subtitle, "USB Mic")
        }
        XCTAssertEqual(microphone.submenu?.items.first?.title, "Default: USB Mic")
        XCTAssertTrue(microphone.submenu?.items.allSatisfy { $0.state == .off } == true, "nothing to pick or check")
    }

    func testPasteActionEnabledOnlyWhenTranscriptExists() {
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: ""))
        XCTAssertFalse(PillContextMenuController.isPasteEnabled(transcript: "   "))
        XCTAssertTrue(PillContextMenuController.isPasteEnabled(transcript: "latest note"))
    }
}
