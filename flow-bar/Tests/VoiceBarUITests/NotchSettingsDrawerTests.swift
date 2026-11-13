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

/// C6 L2c (N16): the Settings drawer's height range and where it is remembered.
final class NotchSettingsDrawerHeightTests: XCTestCase {
    func testTheRangeIsEightToTheRowsTheWindowHoldsWithRoomUnderTheLastRow() {
        XCTAssertEqual(NotchSettingsDrawerPresentation.minimumRows, 8)
        XCTAssertEqual(NotchSettingsDrawerPresentation.maximumRows, 11)
        let window = NotchHistoryMorph.historyCanvasLowerSurfaceHeight
        XCTAssertEqual(window, 560, "History's window grew from 528 pt to hold the tallest drawer")
        let tallest = NotchSettingsDrawerPresentation.lowerSurfaceHeight(rows: 11)
        // Neither a one-line note nor the grip's stretch is ever clamped onto the last row.
        XCTAssertLessThanOrEqual(tallest + VoiceBarNotchContract.transientNoteBandHeight, window)
        XCTAssertLessThanOrEqual(tallest + NotchHistoryMorph.rubberBandRows * NotchHistoryMorph.rowHeight, window)
        // A twelfth row would breach the 640 pt narrow-display guard (window + band + 17 pt outset).
        let twelve = NotchSettingsDrawerPresentation.lowerSurfaceHeight(rows: 12)
            + NotchSettingsDrawerPresentation.bottomClearance
        XCTAssertGreaterThan(VoiceBarNotchContract.topHeight + twelve.rounded(.up) + 17, 640)
        XCTAssertLessThanOrEqual(VoiceBarNotchContract.topHeight + window + 17, 640)
        XCTAssertEqual(NotchSettingsDrawerPresentation.historyListHeight(rows: 8),
                       NotchSettingsDrawerPresentation.historyListHeight)
        XCTAssertEqual(NotchSettingsDrawerPresentation.historyListHeight(rows: 11)
            - NotchSettingsDrawerPresentation.historyListHeight(rows: 8), 3 * NotchHistoryMorph.rowHeight)
    }

    func testAReleasedGripSettlesOnTheNearestWholeRowInRange() {
        XCTAssertEqual(NotchSettingsDrawerPresentation.settledRows(9.4), 9)
        XCTAssertEqual(NotchSettingsDrawerPresentation.settledRows(9.6), 10)
        XCTAssertEqual(NotchSettingsDrawerPresentation.settledRows(11.5), 11)
        XCTAssertEqual(NotchSettingsDrawerPresentation.settledRows(7.4), 8)
        XCTAssertEqual(NotchSettingsDrawerPresentation.settledRows(.nan), 8)
        XCTAssertTrue(NotchHistoryMorph.handleCloses(rawRows: 6.7, minimum: 8))
        XCTAssertFalse(NotchHistoryMorph.handleCloses(rawRows: 6.8, minimum: 8), "a short push only shrinks")
        XCTAssertEqual(NotchHistoryMorph.handleCloses(rawRows: 4.75, minimum: 6),
                       NotchHistoryMorph.handleClosesHistory(rawRows: 4.75))
        XCTAssertEqual(NotchHistoryMorph.rowsRubberBand(13, maximum: 11, minimum: 8), 11.3, accuracy: 0.001)
    }

    func testTheHeightIsRememberedInDefaultsAndClampedOnLoad() throws {
        let suite = "com.voicelayer.tests.n16.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotchSettingsRowsStore.userDefaults(defaults)

        let first = NotchSurfaceModel(settingsRowsStore: store)
        first.log = { _ in }
        XCTAssertEqual(first.settingsRows, 8, "never resized: eight rows")
        first.setSettingsRows(10)
        XCTAssertEqual(defaults.integer(forKey: NotchSettingsRowsStore.defaultsKey), 10)
        XCTAssertEqual(NotchSurfaceModel(settingsRowsStore: store).settingsRows, 10, "a relaunch reopens at ten")

        first.setSettingsRows(40)
        XCTAssertEqual(first.settingsRows, 11)
        defaults.set(2, forKey: NotchSettingsRowsStore.defaultsKey)
        XCTAssertEqual(NotchSurfaceModel(settingsRowsStore: store).settingsRows, 8, "a stale saved value is clamped")
        XCTAssertEqual(NotchSurfaceModel().settingsRows, 8, "the default store is the session only")
    }
}
