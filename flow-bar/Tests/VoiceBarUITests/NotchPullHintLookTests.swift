import Foundation
@testable import VoiceBarUI
import XCTest

final class NotchPullHintLookTests: XCTestCase {
    func testHintIsPositionedInDrawerFreeSpaceRatherThanHandleBand() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        let drawer = try XCTUnwrap(bar.components(separatedBy: "private func notchDrawerContent").last)
            .components(separatedBy: "private var settingsTabShown")[0]
        XCTAssertTrue(drawer.contains("settingsHintProgress:"))
        XCTAssertTrue(drawer.contains("settingsHintOffset:"))
        XCTAssertFalse(drawer.contains("if isSettingsPullArmed, let rect"))
    }
    func testHintFitsBelowEveryVisibleRowAndCentresInOverpullFooter() throws {
        for rows: CGFloat in [6, 8] {
            let fadeBottom = NotchHistoryMorph.listTopInset + NotchHistoryMorph.listHeight(rows: rows)
            for stretch: CGFloat in [0, 12, 36, 60] {
                let bottom = fadeBottom + NotchHistoryMorph.handleBandHeight + stretch
                let rect = try XCTUnwrap(NotchHistoryPresentation.settingsPullHintRect(
                    fadeBottom: fadeBottom, drawerSize: CGSize(width: 420, height: bottom), hintWidth: 160))
                XCTAssertGreaterThanOrEqual(rect.minY, fadeBottom)
                XCTAssertLessThanOrEqual(rect.maxY, bottom)
                XCTAssertEqual(rect.midY, (fadeBottom + bottom) / 2, accuracy: 0.5)
                XCTAssertEqual(rect.midX, 210)
                for row in 0..<Int(rows) {
                    let rowRect = CGRect(x: 0, y: 8 + CGFloat(row) * 46, width: 420, height: 46)
                    XCTAssertFalse(rect.intersects(rowRect))
                }
            }
        }
        XCTAssertNil(NotchHistoryPresentation.settingsPullHintRect(
            fadeBottom: 284, drawerSize: CGSize(width: 420, height: 290), hintWidth: 160))
    }

}
