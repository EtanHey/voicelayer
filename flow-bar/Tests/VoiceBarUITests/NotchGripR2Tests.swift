import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest
@MainActor final class NotchGripR2Tests: XCTestCase {
    func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/" + name + ".swift"))
    }
    func testGripHasOnePersistentShapeAndUsesDrawerSpring() throws {
        let bar = try source("BarView")
        let handle = try source("NotchHistoryExtendHandle")
        let hint = try source("NotchSettingsPullHint")
        XCTAssertFalse(bar.contains("if isSettingsPullArmed, let rect"))
        XCTAssertTrue(handle.contains("NotchSettingsPullHint("))
        XCTAssertTrue(hint.contains("var progress: CGFloat"))
        XCTAssertTrue(hint.contains("NotchHistoryMorph.springResponse"))
        XCTAssertTrue(hint.contains("reduceMotion ? nil"))
        XCTAssertFalse(hint.contains(".transition("))
    }
    func testCompactFooterAndReduceMotion() throws {
        let (rect, _, fade, bottom) = try NotchGripPaintTests.render(progress: 1, rows: 6, light: false)
        XCTAssertEqual(rect.minY - fade, 8, accuracy: 0.5)
        XCTAssertEqual(bottom - rect.maxY, 8, accuracy: 0.5)
        for p: CGFloat in [0, 0.5, 1] {
            XCTAssertEqual(NotchSettingsPullHint.phase(p, reduceMotion: false), p)
            XCTAssertEqual(NotchSettingsPullHint.phase(p, reduceMotion: true), p == 1 ? 1 : 0)
        }
    }
}
