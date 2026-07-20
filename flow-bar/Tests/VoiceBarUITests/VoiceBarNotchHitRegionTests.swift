@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchHitRegionTests: XCTestCase {
    func testRecordingRegionContainsLeadingCoreAndTrailingStrips() {
        let geometry = VoiceBarNotchContract.geometry(for: .recording)
        let region = VoiceBarNotchHitRegion(geometry: geometry)

        XCTAssertEqual(region.rects, [CGRect(x: 0, y: 0, width: 358, height: 32)])
        XCTAssertTrue(region.contains(CGPoint(x: 10, y: 16)))
        XCTAssertTrue(region.contains(CGPoint(x: 150, y: 16)))
        XCTAssertTrue(region.contains(CGPoint(x: 350, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: 197, y: 40)))
    }

    func testCompactRoundedCornersPassThroughOutsideTheRenderedGlass() {
        let region = VoiceBarNotchHitRegion(
            geometry: VoiceBarNotchContract.geometry(for: .recording)
        )

        XCTAssertFalse(region.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(region.contains(CGPoint(x: 357, y: 1)))
        XCTAssertTrue(region.contains(CGPoint(x: 16, y: 16)))
        XCTAssertTrue(region.contains(CGPoint(x: 342, y: 16)))
    }

    func testTeleprompterRegionIsTheTopBarPlusLowerBodyUnion() {
        let geometry = VoiceBarNotchContract.geometry(for: .teleprompter)
        let region = VoiceBarNotchHitRegion(geometry: geometry)

        XCTAssertEqual(region.rects, [
            CGRect(x: 58, y: 196, width: 361, height: 32),
            CGRect(x: 0, y: 0, width: 465, height: 196),
        ])
        XCTAssertEqual(geometry.coreOriginX, 140)
        XCTAssertEqual(geometry.coreMidX, geometry.totalWidth / 2)
        XCTAssertTrue(region.contains(CGPoint(x: 232.5, y: 212)))
        XCTAssertTrue(region.contains(CGPoint(x: 10, y: 190)))
        XCTAssertFalse(region.contains(CGPoint(x: 10, y: 212)))
        XCTAssertFalse(region.contains(CGPoint(x: 455, y: 212)))
    }

    func testTeleprompterRoundedBodyCornersPassThroughOutsideTheContinuousSurface() {
        let region = VoiceBarNotchHitRegion(
            geometry: VoiceBarNotchContract.geometry(for: .teleprompter)
        )

        XCTAssertFalse(region.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(region.contains(CGPoint(x: 464, y: 1)))
        XCTAssertTrue(region.contains(CGPoint(x: 18, y: 18)))
        XCTAssertTrue(region.contains(CGPoint(x: 447, y: 18)))
    }

    func testIdleRegionDoesNotAddPixelsBeyondTheHardwareCore() {
        let region = VoiceBarNotchHitRegion(
            geometry: VoiceBarNotchContract.geometry(for: .idle)
        )

        XCTAssertEqual(region.bounds, CGRect(x: 0, y: 0, width: 185, height: 32))
        XCTAssertTrue(region.contains(CGPoint(x: 92.5, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: 186, y: 16)))
    }
}
