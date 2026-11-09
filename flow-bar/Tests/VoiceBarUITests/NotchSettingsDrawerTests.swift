import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A: the Settings drawer's copy and layout rules.
final class NotchSettingsDrawerTests: XCTestCase {
    private static var allCopy: [String] {
        var copy = [
            NotchSettingsDrawerPresentation.versionTitle, NotchSettingsDrawerPresentation.checkForUpdates,
            NotchSettingsDrawerPresentation.releaseNotes, NotchSettingsDrawerPresentation.updateButtonTitle("2.4.0"),
            NotchUpdateController.dictatingRefusal, NotchUpdateController.noUpdaterRefusal,
        ]
        copy += SettingsTab.allCases.map(NotchSettingsDrawerPresentation.tabDescription)
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

    /// 0510 N1: the real panes get the most room the window already has: expanded History's eight rows, so the
    /// History/Settings swap never resizes the window.
    func testTheDrawerTakesExpandedHistorysHeight() {
        XCTAssertEqual(NotchSettingsDrawerPresentation.lowerSurfaceHeight, 8 + 8 * 46 + 18)
        XCTAssertEqual(NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                       NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(NotchHistoryMorph.maximumRows)))
        XCTAssertLessThanOrEqual(NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                                 NotchHistoryMorph.historyCanvasLowerSurfaceHeight)
    }

    func testTheRightClickRecentsStayAtEightWhileHistoryHoldsTwenty() {
        let controller = PillContextMenuController()
        controller.recentTranscriptionEntriesProvider = {
            (0 ..< 20).map { RecentTranscriptionEntry(text: "dictation \($0)") }
        }
        XCTAssertEqual(controller.makeRecentTranscriptsSubmenu().items.count, 8)
    }
}
