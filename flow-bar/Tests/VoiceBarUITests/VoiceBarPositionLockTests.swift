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
        XCTAssertNotNil(topPlacement.verticalOffset)
        XCTAssertFalse(topPlacement.followsMouse)
        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset, topPlacement.verticalOffset)
        XCTAssertFalse(placement.followsMouse)
    }

    func testAnchoredModesPlaceBarBehindTopNotchBand() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let pillSize = CGSize(width: 190, height: 50)
        let expectedTopY = visibleFrame.maxY + 22

        for mode in VoiceBarAnchorMode.anchoredPositionModes {
            let placement = mode.placement(visibleFrame: visibleFrame, pillSize: pillSize)
            let minY = visibleFrame.origin.y
                + (visibleFrame.height * (placement.verticalOffset ?? -1))
                - (pillSize.height / 2)

            XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
            XCTAssertEqual(minY + pillSize.height, expectedTopY, accuracy: 0.001)
            XCTAssertFalse(placement.followsMouse)
        }
    }

    func testPanelDragDecisionRespectsLock() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48)))

        panel.isPillDragEnabled = false
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: true))

        panel.isPillDragEnabled = true
        XCTAssertTrue(panel.shouldHandlePillDrag(startedInVisiblePill: true))
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: false))
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
