@testable import VoiceBarUI
import XCTest

final class VoiceBarMenuTests: XCTestCase {
    func testQuickActionMenuContainsRequestedItemsInOrder() {
        let actions = VoiceBarMenu.quickActions(
            openSettings: {},
            showVoiceBar: {},
            snoozeToggle: {},
            transcribeLatestRecording: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions.map(\.title), [
            "Settings",
            "Show VoiceBar",
            "Hide for 1 hour",
            "Transcribe latest recording",
            "Paste last transcript",
            "Quit VoiceBar",
        ])
    }

    func testQuickActionMenuInvokesEachCallback() {
        var invoked: [String] = []
        let actions = VoiceBarMenu.quickActions(
            openSettings: { invoked.append("settings") },
            showVoiceBar: { invoked.append("show") },
            snoozeToggle: { invoked.append("snooze") },
            transcribeLatestRecording: { invoked.append("recover") },
            pasteLastTranscript: { invoked.append("paste") },
            quit: { invoked.append("quit") }
        )

        actions.forEach { $0.perform() }

        XCTAssertEqual(invoked, ["settings", "show", "snooze", "recover", "paste", "quit"])
    }

    func testMenuBarIncludesShowAndHideWhenNotSnoozed() {
        let actions = VoiceBarMenu.quickActions(
            isSnoozed: false,
            openSettings: {},
            showVoiceBar: {},
            snoozeToggle: {},
            transcribeLatestRecording: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions.map(\.title).prefix(3), [
            "Settings",
            "Show VoiceBar",
            "Hide for 1 hour",
        ])
    }

    func testMenuBarKeepsShowVoiceBarWhenSnoozedWithoutDuplicateToggle() {
        let actions = VoiceBarMenu.quickActions(
            isSnoozed: true,
            openSettings: {},
            showVoiceBar: {},
            snoozeToggle: {},
            transcribeLatestRecording: {},
            pasteLastTranscript: {},
            quit: {}
        )

        XCTAssertEqual(actions.map(\.title), [
            "Settings",
            "Show VoiceBar",
            "Transcribe latest recording",
            "Paste last transcript",
            "Quit VoiceBar",
        ])
    }
}
