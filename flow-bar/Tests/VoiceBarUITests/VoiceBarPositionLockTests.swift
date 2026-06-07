import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceBarPositionLockTests: XCTestCase {
    func testFollowModeKeepsSavedOffsetsAndScreenFollowing() {
        let placement = VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: .follow,
            savedHorizontalOffset: 0.2,
            savedVerticalOffset: 0.3,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            pillSize: CGSize(width: 190, height: 50)
        )

        XCTAssertEqual(placement.horizontalOffset, 0.2, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset ?? -1, 0.3, accuracy: 0.001)
        XCTAssertTrue(placement.followsMouse)
    }

    func testTopAndBottomCenterIgnoreSavedDragOffsets() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let pillSize = CGSize(width: 190, height: 50)
        let topPlacement = VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: .topCenter,
            savedHorizontalOffset: 0.2,
            savedVerticalOffset: 0.3,
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )
        let placement = VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: .bottomCenter,
            savedHorizontalOffset: 0.2,
            savedVerticalOffset: 0.3,
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )

        XCTAssertEqual(topPlacement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertNil(topPlacement.verticalOffset)
        XCTAssertTrue(topPlacement.menuBarAttached)
        XCTAssertFalse(topPlacement.followsMouse)
        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(
            placement.verticalOffset ?? -1,
            (24 + (pillSize.height / 2)) / visibleFrame.height,
            accuracy: 0.001
        )
        XCTAssertFalse(placement.menuBarAttached)
        XCTAssertFalse(placement.followsMouse)
    }

    func testPanelDragDecisionRespectsLock() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48)))

        panel.isPillDragEnabled = false
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: true))

        panel.isPillDragEnabled = true
        XCTAssertTrue(panel.shouldHandlePillDrag(startedInVisiblePill: true))
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: false))
    }

    func testFullEnvelopePanelPassesMouseDownThroughOutsideActiveHitRect() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 1728, height: 503)))
        panel.activeHitRectProvider = {
            NSRect(x: 700, y: 0, width: 328, height: 32)
        }
        let outside = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 864, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!

        XCTAssertTrue(panel.shouldPassThroughMouseEvent(outside))
        XCTAssertFalse(panel.activeHitRectContains(pointInWindow: outside.locationInWindow))
    }

    func testFullEnvelopePanelKeepsMouseDownInsideActiveHitRect() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 1728, height: 503)))
        panel.activeHitRectProvider = {
            NSRect(x: 700, y: 0, width: 328, height: 32)
        }
        let inside = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 864, y: 16),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!

        XCTAssertFalse(panel.shouldPassThroughMouseEvent(inside))
        XCTAssertTrue(panel.activeHitRectContains(pointInWindow: inside.locationInWindow))
    }

    func testScreenFollowPolicySelectsMouseScreenForAnchoredModes() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1200, height: 800),
            CGRect(x: 1200, y: 0, width: 1000, height: 700),
        ]

        XCTAssertEqual(
            VoiceBarScreenFollowPolicy.targetScreenIndex(
                mouseLocation: CGPoint(x: 1300, y: 400),
                screenFrames: screens
            ),
            1
        )
        XCTAssertNil(
            VoiceBarScreenFollowPolicy.targetScreenIndex(
                mouseLocation: CGPoint(x: -20, y: 400),
                screenFrames: screens
            )
        )
    }
}
