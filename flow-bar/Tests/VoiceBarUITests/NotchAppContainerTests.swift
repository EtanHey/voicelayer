import AppKit
@testable import VoiceBarUI
import XCTest

final class NotchAppContainerTests: XCTestCase {
    func testPanelUsesMenuBarNotchWindowRecipe() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 185, height: 36)))

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.hudWindow))
        XCTAssertEqual(panel.animationBehavior, .utilityWindow)
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isOpaque)
    }

    func testClosedNotchGeometryUsesHardwareNotchMetrics() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 944, width: 664, height: 38)
        let right = CGRect(x: 848, y: 944, width: 664, height: 38)
        let metrics = NotchAppScreenMetrics(
            frame: frame,
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right
        )

        XCTAssertEqual(NotchAppGeometry.closedSize(for: metrics), CGSize(width: 188, height: 38))
        XCTAssertEqual(
            NotchAppGeometry.frame(for: CGSize(width: 188, height: 38), on: metrics),
            CGRect(x: 662, y: 944, width: 188, height: 38)
        )
    }
}
