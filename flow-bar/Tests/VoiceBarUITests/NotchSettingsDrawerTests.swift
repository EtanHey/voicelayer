import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A: the Settings drawer's copy and layout rules.
final class NotchSettingsDrawerTests: XCTestCase {
    private static var allCopy: [String] {
        var copy = [
            NotchSettingsDrawerPresentation.allSetTitle, NotchSettingsDrawerPresentation.allSetDetail,
            NotchSettingsDrawerPresentation.shortcutTitle, NotchSettingsDrawerPresentation.microphoneTitle,
            NotchSettingsDrawerPresentation.versionTitle, NotchSettingsDrawerPresentation.checkForUpdates,
            NotchSettingsDrawerPresentation.releaseNotes, NotchSettingsDrawerPresentation.allSettings,
            NotchSettingsDrawerPresentation.updateButtonTitle("2.4.0"),
            NotchUpdateController.dictatingRefusal, NotchUpdateController.noUpdaterRefusal,
        ]
        for tab in SettingsTab.allCases {
            copy += [NotchSettingsDrawerPresentation.tabDescription(tab), NotchSettingsDrawerPresentation.openTabTitle(tab)]
        }
        for permission in [HotkeyPermission.microphone, .accessibility, .inputMonitoring] {
            copy += [NotchSettingsDrawerPresentation.permissionTitle(permission),
                     NotchSettingsDrawerPresentation.permissionDetail(permission)]
        }
        let summary = NotchSettingsDrawerPresentation.permissionSummary([.microphone, .accessibility])
        copy += [summary.title, summary.detail]
        let phases: [NotchUpdatePhase] = [.checking, .upToDate, .ahead(latest: "2.2.61"), .available(version: "2.4.0"),
                                          .couldNotCheck, .updating]
        copy += phases.compactMap(NotchSettingsDrawerPresentation.updateStatus)
        return copy
    }

    /// Etan dislikes em dashes and double hyphens in user-visible copy.
    func testNoEmDashesOrDoubleHyphensInDrawerCopy() {
        for text in Self.allCopy {
            XCTAssertFalse(text.contains("—"), text)
            XCTAssertFalse(text.contains("--"), text)
        }
    }

    func testTheMicrophoneNameStaysOnOneLineWithinItsBudget() {
        let long = "Etan's\nVery Long External USB Audio Interface Microphone Input Channel 1 and 2"
        let line = NotchSettingsDrawerPresentation.microphoneLine(long)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertTrue(line.hasPrefix("Default: "))
        XCTAssertLessThanOrEqual(NotchSettingsDrawerPresentation.measure(line),
                                 NotchSettingsDrawerPresentation.microphoneNameWidthBudget)
        XCTAssertEqual(NotchSettingsDrawerPresentation.microphoneLine("MacBook Pro Microphone"),
                       "Default: MacBook Pro Microphone", "a name that fits is never cut")
        XCTAssertEqual(NotchSettingsDrawerPresentation.microphoneLine(nil), "Default: Unavailable")
    }

    func testOneRowSummarisesSeveralMissingPermissions() {
        let one = NotchSettingsDrawerPresentation.permissionSummary([.accessibility])
        XCTAssertEqual(one.title, "Accessibility is off")
        let many = NotchSettingsDrawerPresentation.permissionSummary([.microphone, .accessibility, .inputMonitoring])
        XCTAssertEqual(many.title, "3 permissions are off")
        XCTAssertEqual(many.detail, "Microphone, Accessibility, Input Monitoring")
    }

    func testTheDrawerIsExactlyTheExpandedHistoryHeight() {
        XCTAssertEqual(NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                       NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(NotchHistoryMorph.maximumRows)))
        XCTAssertEqual(NotchSettingsDrawerPresentation.lowerSurfaceHeight, 8 + 8 * 46 + 18)
    }

    func testTheRightClickRecentsStayAtEightWhileHistoryHoldsTwenty() {
        let controller = PillContextMenuController()
        controller.recentTranscriptionEntriesProvider = {
            (0 ..< 20).map { RecentTranscriptionEntry(text: "dictation \($0)") }
        }
        XCTAssertEqual(controller.makeRecentTranscriptsSubmenu().items.count, 8)
    }
}
