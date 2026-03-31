@testable import VoiceBar
import XCTest

final class VoiceBarMenuTests: XCTestCase {
    func testQuickActionMenuContainsRequestedItemsInOrder() {
        let actions = VoiceBarMenu.quickActions(
            openSettings: {},
            snoozeToggle: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions.map(\.title), [
            "Settings",
            "Hide for 1 hour",
            "Paste last transcript",
            "Quit VoiceBar",
        ])
    }

    func testQuickActionMenuInvokesEachCallback() {
        var invoked: [String] = []
        let actions = VoiceBarMenu.quickActions(
            openSettings: { invoked.append("settings") },
            snoozeToggle: { invoked.append("snooze") },
            pasteLastTranscript: { invoked.append("paste") },
            quit: { invoked.append("quit") }
        )

        actions.forEach { $0.perform() }

        XCTAssertEqual(invoked, ["settings", "snooze", "paste", "quit"])
    }

    func testSnoozeToggleShowsHideWhenNotSnoozed() {
        let actions = VoiceBarMenu.quickActions(
            isSnoozed: false,
            openSettings: {},
            snoozeToggle: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions[1].title, "Hide for 1 hour")
    }

    func testSnoozeToggleShowsShowWhenSnoozed() {
        let actions = VoiceBarMenu.quickActions(
            isSnoozed: true,
            openSettings: {},
            snoozeToggle: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions[1].title, "Show VoiceBar")
    }
}
