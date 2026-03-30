@testable import VoiceBar
import XCTest

final class VoiceBarMenuTests: XCTestCase {
    func testQuickActionMenuContainsRequestedItemsInOrder() {
        let actions = VoiceBarMenu.quickActions(
            openSettings: {},
            hideForOneHour: {},
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
            hideForOneHour: { invoked.append("hide") },
            pasteLastTranscript: { invoked.append("paste") },
            quit: { invoked.append("quit") }
        )

        actions.forEach { $0.perform() }

        XCTAssertEqual(invoked, ["settings", "hide", "paste", "quit"])
    }
}
