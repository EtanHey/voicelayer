@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class VoiceBarAnchorModeTests: XCTestCase {
    func testAnchorModeDefaultsToFollowWhenMissingOrUnknown() {
        XCTAssertEqual(VoiceBarAnchorMode(defaultsValue: nil), .follow)
        XCTAssertEqual(VoiceBarAnchorMode(defaultsValue: "wide-orange"), .follow)
    }

    func testBottomCenterAnchorUsesCenteredXAndDockClearedYOffset() {
        let visibleFrame = CGRect(x: 40, y: 80, width: 1440, height: 900)
        let pillSize = CGSize(width: 190, height: 50)

        let placement = VoiceBarAnchorMode.bottomCenter.placement(
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )

        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset ?? -1, (24 + (pillSize.height / 2)) / visibleFrame.height, accuracy: 0.001)
        XCTAssertFalse(placement.followsMouse)
    }

    func testFollowAnchorKeepsLegacyTopCenterMouseFollowing() {
        let placement = VoiceBarAnchorMode.follow.placement(
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            pillSize: CGSize(width: 190, height: 50)
        )

        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertNil(placement.verticalOffset)
        XCTAssertTrue(placement.followsMouse)
    }
}
