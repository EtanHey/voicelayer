@testable import VoiceBarUI
import XCTest

/// R4 UI pass #15 (Check shortcut changed nothing on screen) and #14 (Hidden didn't say until when).
final class SettingsFeedbackTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 14:13:20 UTC

    func testACheckSaysWhenItRanAndWhetherItPassed() {
        let ready = SettingsShortcutCheck.message(
            hotkeyEnabled: true, missingPermissions: [], relayReady: true, relaySummary: ""
        )
        XCTAssertEqual(
            SettingsShortcutCheck.feedback(message: ready, checkedAt: now, now: now),
            "Checked ✓ just now · Shortcut ready: F5 listener and relay are active."
        )
        XCTAssertEqual(
            SettingsShortcutCheck.feedback(message: ready, checkedAt: now.addingTimeInterval(-130), now: now),
            "Checked ✓ 2 min ago · Shortcut ready: F5 listener and relay are active."
        )

        let failed = SettingsShortcutCheck.message(
            hotkeyEnabled: false, missingPermissions: [], relayReady: true, relaySummary: ""
        )
        XCTAssertEqual(
            SettingsShortcutCheck.feedback(message: failed, checkedAt: now, now: now),
            "Checked just now · Shortcut needs attention: F5 listener unavailable."
        )
    }

    func testHiddenSaysUntilWhen() {
        XCTAssertEqual(
            SettingsVisibility.hiddenStatus(until: now.addingTimeInterval(3600), calendar: calendar),
            "Hidden until 15:13"
        )
        XCTAssertEqual(SettingsVisibility.hiddenStatus(until: nil, calendar: calendar), "Hidden",
                       "without a known end time it still says Hidden, never a wrong time")
    }
}
