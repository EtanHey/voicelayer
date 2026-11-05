import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.3 SPEC lane U1: the bare-notch menu and the Dock menu, item for item, through the right-click adapters.
final class BareNotchMenuTests: XCTestCase {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func controller() -> PillContextMenuController {
        let controller = PillContextMenuController()
        controller.versionProvider = { "2.3.0" }
        return controller
    }

    func testNotchMenuMatchesTheSpecList() throws {
        let controller = controller()
        controller.updateStatusProvider = { "up to date" }
        let menu = controller.makeNotchMenu()
        XCTAssertEqual(titles(menu), [
            "Copy last transcript", "Paste last transcript", "Transcribe latest again",
            "—", "Settings…", "Hide for 1 hour",
            "—", "VoiceBar 2.3.0 · up to date", "Quit VoiceBar",
        ])
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "VoiceBar 2.3.0 · up to date")).isEnabled)
        XCTAssertEqual(menu.item(withTitle: "Settings…")?.keyEquivalent, ",")
        XCTAssertEqual(menu.item(withTitle: "Quit VoiceBar")?.keyEquivalent, "q")
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil },
                      "Recent Transcriptions and Microphone are not in the notch menu")
    }

    func testVersionRowNeverClaimsAnUpdateCheckThatDidNotHappen() {
        XCTAssertEqual(PillContextMenuController.versionLine(version: "2.3.0", updateStatus: nil), "VoiceBar 2.3.0")
        XCTAssertEqual(PillContextMenuController.versionLine(version: "", updateStatus: nil), "VoiceBar")
        XCTAssertEqual(titles(controller().makeNotchMenu())[7], "VoiceBar 2.3.0")
    }

    func testDockMenuLeavesQuitToTheSystem() {
        XCTAssertEqual(titles(controller().makeDockMenu()), [
            "Copy last transcript", "Paste last transcript",
            "—", "Settings…", "Hide notch for 1 hour",
        ])
    }

    func testSnoozedMenusOfferShowVoiceBar() {
        let controller = controller()
        controller.isSnoozedProvider = { true }
        XCTAssertNotNil(controller.makeNotchMenu().item(withTitle: "Show VoiceBar"))
        XCTAssertNotNil(controller.makeDockMenu().item(withTitle: "Show VoiceBar"))
        XCTAssertNil(controller.makeDockMenu().item(withTitle: "Hide notch for 1 hour"))
    }

    func testTranscriptRowsFollowTheLatestTranscriptAndRetranscribeReadiness() throws {
        let controller = controller()
        let empty = controller.makeNotchMenu()
        XCTAssertFalse(try XCTUnwrap(empty.item(withTitle: "Copy last transcript")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(empty.item(withTitle: "Paste last transcript")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(empty.item(withTitle: "Transcribe latest again")).isEnabled)
        controller.transcriptProvider = { "hello" }
        controller.canRetranscribeLatestProvider = { true }
        let ready = controller.makeNotchMenu()
        XCTAssertTrue(try XCTUnwrap(ready.item(withTitle: "Copy last transcript")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(ready.item(withTitle: "Transcribe latest again")).isEnabled)
    }

    /// Every row routes through the adapter the right-click menu already uses.
    func testEveryRowCallsTheExistingAdapter() throws {
        let controller = controller()
        controller.transcriptProvider = { "hello" }
        controller.canRetranscribeLatestProvider = { true }
        var calls: [String] = []
        controller.onCopyLastTranscript = { calls.append("copy") }
        controller.onPasteLastTranscript = { calls.append("paste") }
        controller.onRetranscribeLatest = { calls.append("again") }
        controller.onOpenSettings = { calls.append("settings") }
        controller.onSnooze = { calls.append("snooze") }
        controller.onQuit = { calls.append("quit") }
        for item in controller.makeNotchMenu().items where item.action != nil {
            _ = item.target?.perform(item.action, with: item)
        }
        XCTAssertEqual(calls, ["copy", "paste", "again", "settings", "snooze", "quit"])
        calls.removeAll()
        for item in controller.makeDockMenu().items where item.action != nil {
            _ = item.target?.perform(item.action, with: item)
        }
        XCTAssertEqual(calls, ["copy", "paste", "settings", "snooze"])
    }

    func testBareNotchKeys() {
        XCTAssertEqual(BareNotchKeyCommand.resolve(keyCode: 36), .openMenu)
        XCTAssertEqual(BareNotchKeyCommand.resolve(keyCode: 76), .openMenu)
        XCTAssertEqual(BareNotchKeyCommand.resolve(keyCode: 125), .openHistory)
        XCTAssertEqual(BareNotchKeyCommand.resolve(keyCode: 125, modifiers: [.numericPad, .function]), .openHistory,
                       "arrow keys always carry these device flags")
        XCTAssertEqual(BareNotchKeyCommand.resolve(keyCode: 53), .close)
        XCTAssertNil(BareNotchKeyCommand.resolve(keyCode: 125, modifiers: .command))
        XCTAssertNil(BareNotchKeyCommand.resolve(keyCode: 36, modifiers: .option))
        XCTAssertNil(BareNotchKeyCommand.resolve(keyCode: 126), "↑ does nothing on the bare notch")
    }

    func testBareNotchIsNamedForItsAction() {
        XCTAssertEqual(BareNotchAccessibility.label, "VoiceBar menu")
        XCTAssertEqual(BareNotchAccessibility.help, "Click for the menu, pull down for History.")
    }

    @MainActor
    func testPresenterIsExpandedExactlyWhileTheMenuTracks() {
        var duringPopUp: [Bool] = []
        var changes: [Bool] = []
        var presenter: BareNotchMenuPresenter!
        presenter = BareNotchMenuPresenter { _, _, _ in
            duringPopUp.append(presenter.isExpanded)
            // A second request while tracking (a re-click, Return) must not stack a second menu.
            XCTAssertFalse(presenter.present(NSMenu(), at: .zero, in: NSView()))
        }
        presenter.onExpandedChange = { changes.append($0) }
        XCTAssertTrue(presenter.present(NSMenu(), at: .zero, in: NSView()))
        XCTAssertEqual(duringPopUp, [true])
        XCTAssertEqual(changes, [true, false])
        XCTAssertFalse(presenter.isExpanded)
    }
}
