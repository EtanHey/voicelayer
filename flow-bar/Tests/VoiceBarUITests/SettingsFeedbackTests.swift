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

    /// en_US writes the month first, which is where the old lowercasing showed ("sep 18").
    private var usCalendar: Calendar {
        var calendar = calendar
        calendar.locale = Locale(identifier: "en_US")
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

    /// #163 review: "Checked sep 18" lowercased the month. Only the relative words are lowercased.
    func testOlderChecksKeepTheDateCapitalised() {
        let ready = SettingsShortcutCheck.message(
            hotkeyEnabled: true, missingPermissions: [], relayReady: true, relaySummary: ""
        )
        XCTAssertEqual(
            SettingsShortcutCheck.feedback(message: ready, checkedAt: now.addingTimeInterval(-3 * 86400),
                                           now: now, calendar: usCalendar),
            "Checked ✓ Sep 18 · Shortcut ready: F5 listener and relay are active.",
            "the locale's own date, capitalised as the locale writes it (was \"sep 18\")"
        )
        XCTAssertEqual(
            SettingsShortcutCheck.feedback(message: ready, checkedAt: now.addingTimeInterval(-20 * 3600),
                                           now: now, calendar: calendar),
            "Checked ✓ yesterday · Shortcut ready: F5 listener and relay are active."
        )
    }

    /// #163 review: a VoiceBar hidden by choice isn't broken, so its dot is neutral, not red.
    func testHiddenByChoiceUsesANeutralDot() {
        XCTAssertEqual(SettingsVisibility.tone(isHidden: true), .neutral)
        XCTAssertEqual(SettingsVisibility.tone(isHidden: false), .ready)
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
