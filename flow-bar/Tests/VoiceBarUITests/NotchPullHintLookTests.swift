import Foundation
import AppKit
@testable import VoiceBarUI
import XCTest

@MainActor final class NotchPullHintLookTests: XCTestCase {
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
            for p: CGFloat in [0, 0.5, 1] {
                let (rect, _, fade, bottom) = try NotchGripPaintTests.render(progress: p, rows: rows, light: false)
                XCTAssertGreaterThanOrEqual(rect.minY, fade)
                XCTAssertLessThanOrEqual(rect.maxY, bottom)
                XCTAssertEqual(rect.midY, (fade + bottom) / 2, accuracy: 0.5)
                XCTAssertEqual(rect.midX, 210, accuracy: 0.5)
            }
        }
    }

}
