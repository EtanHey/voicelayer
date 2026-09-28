@testable import VoiceBarUI
import XCTest

/// H1-d part 2 (UI pass #9 / #10): the list gets most of the height, re-entering History selects the newest row,
/// and the Ask list has no empty band above its first date.
final class SettingsHistoryLayoutTests: XCTestCase {
    /// UI pass #9: list and detail were each ~200 pt (3.5 rows visible).
    func testTheListAlwaysGetsMostOfTheHeight() {
        for available: CGFloat in [300, 400, 520, 700, 1000] {
            let detail = SettingsHistoryLayout.detailHeight(available: available)
            XCTAssertLessThan(detail, available - detail, "available \(available)")
        }
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 300), 114, accuracy: 0.001)
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 1000), 220)
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 100), 110)
    }

    func testReenteringHistorySelectsTheNewestRow() {
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "older", entries: ["newest", "older"], preferNewest: true),
            "newest"
        )
    }

    func testOtherwiseTheSelectionStaysWhileItIsOnThePage() {
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "older", entries: ["newest", "older"], preferNewest: false),
            "older"
        )
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "gone", entries: ["newest", "older"], preferNewest: false),
            "newest"
        )
        XCTAssertEqual(SettingsHistoryLayout.selection(current: nil, entries: [], preferNewest: false), nil)
    }

    func testTheViewUsesTheLayoutRules() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("SettingsHistoryLayout.detailHeight(available: geometry.size.height)"))
        XCTAssertFalse(source.contains(".frame(maxHeight: 260)"), "the fixed 260 pt detail cap is gone")
        XCTAssertTrue(source.contains("preferNewest: selectNewestOnNextHistoryPage"))
        XCTAssertTrue(source.contains(".padding(.top, SettingsHistoryLayout.askListTopInset)"))
        XCTAssertLessThanOrEqual(SettingsHistoryLayout.askListTopInset, 8)
        XCTAssertTrue(source.contains("Color.clear.frame(height: 0).id(latestAskHistoryAnchorID)"),
                      "the Ask scroll anchor sits behind the stack, so no stack spacing follows it")
        // Re-entering the History tab asks for the newest row.
        let tabChange = try XCTUnwrap(source.range(of: ".onChange(of: selectedTab) { _, tab in"))
        let body = source[tabChange.lowerBound...].prefix(600)
        XCTAssertTrue(body.contains("selectNewestOnNextHistoryPage = true"))
    }
}
