@testable import VoiceBarUI
import AppKit
import XCTest

final class VoiceBarPositionLockTests: XCTestCase {
    func testLockedFollowModeKeepsSavedOffsetsAndScreenFollowing() {
        let placement = VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: .follow,
            isLocked: true,
            savedHorizontalOffset: 0.2,
            savedVerticalOffset: 0.3,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            pillSize: CGSize(width: 190, height: 50)
        )

        XCTAssertEqual(placement.horizontalOffset, 0.2, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset ?? -1, 0.3, accuracy: 0.001)
        XCTAssertTrue(placement.followsMouse)
    }

    func testUnlockedFollowModeKeepsSavedOffsetsAndMouseFollowing() {
        let placement = VoiceBarPositionLockPolicy.effectivePlacement(
            anchorMode: .follow,
            isLocked: false,
            savedHorizontalOffset: 0.2,
            savedVerticalOffset: 0.3,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            pillSize: CGSize(width: 190, height: 50)
        )

        XCTAssertEqual(placement.horizontalOffset, 0.2, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset ?? -1, 0.3, accuracy: 0.001)
        XCTAssertTrue(placement.followsMouse)
    }

    func testPanelDragDecisionRespectsLock() {
        let panel = FloatingPillPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48)))

        panel.isPillDragEnabled = false
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: true))

        panel.isPillDragEnabled = true
        XCTAssertTrue(panel.shouldHandlePillDrag(startedInVisiblePill: true))
        XCTAssertFalse(panel.shouldHandlePillDrag(startedInVisiblePill: false))
    }

    func testLockFootnoteDoesNotOverrideAnchorState() {
        XCTAssertNil(VoiceBarPositionLockPolicy.lockFootnote(anchorMode: .follow, isLocked: true))
        XCTAssertNil(VoiceBarPositionLockPolicy.lockFootnote(anchorMode: .bottomCenter, isLocked: true))
        XCTAssertNil(VoiceBarPositionLockPolicy.lockFootnote(anchorMode: .follow, isLocked: false))
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
