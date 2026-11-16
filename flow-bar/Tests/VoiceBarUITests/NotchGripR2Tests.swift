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
        let closed = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let open = VoiceBarNotchContract.geometry(for: .history)
        let morph = VoiceBarNotchHistoryMorphInput(progress: 1.3, closed: closed, open: open)
        let bottom = morph.geometry(at: NotchHistoryMorph.rubberBand(NotchHistoryMorph.settingsPullThreshold)).lowerSurfaceHeight
        let fade = open.lowerSurfaceHeight - NotchHistoryMorph.handleBandHeight
        let rect = try XCTUnwrap(NotchHistoryPresentation.settingsPullHintRect(fadeBottom: fade,
            drawerSize: CGSize(width: 420, height: bottom), hintWidth: 160))
        XCTAssertEqual(rect.minY - fade, 8, accuracy: 0.5)
        XCTAssertEqual(bottom - rect.maxY, 8, accuracy: 0.5)
        XCTAssertFalse(rect.intersects(CGRect(x: 0, y: 0, width: 420, height: fade)))
        for p: CGFloat in [0, 0.5, 1] {
            XCTAssertEqual(NotchSettingsPullHint.phase(p, reduceMotion: false), p)
            XCTAssertEqual(NotchSettingsPullHint.phase(p, reduceMotion: true), p == 1 ? 1 : 0)
        }
    }
}
