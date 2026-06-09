@testable import VoiceBarUI
import XCTest

final class NotchIslandGeometryTests: XCTestCase {
    func testTopIslandFrameIsFlushToFullScreenTop() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let contentSize = CGSize(width: 220, height: 42)

        let geometry = NotchIslandGeometry.make(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )

        XCTAssertEqual(geometry.windowFrame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(geometry.windowFrame.maxY, visibleFrame.maxY)
        XCTAssertEqual(geometry.windowFrame.midX, screenFrame.midX, accuracy: 0.001)
    }

    func testTopIslandEnvelopeWrapsAroundNotchPocket() {
        let geometry = NotchIslandGeometry.make(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            contentSize: CGSize(width: 220, height: 42)
        )

        XCTAssertGreaterThanOrEqual(geometry.windowFrame.width, geometry.notchPocket.width + 220)
        XCTAssertEqual(geometry.notchPocket.midX, geometry.localBounds.midX, accuracy: 0.001)
        XCTAssertEqual(geometry.notchPocket.maxY, geometry.localBounds.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(geometry.contentRect.maxY, geometry.notchPocket.minY)
    }

    func testActiveHitRegionsExcludePhysicalNotchPocket() {
        let geometry = NotchIslandGeometry.make(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            contentSize: CGSize(width: 220, height: 42)
        )

        XCTAssertFalse(geometry.containsActiveHitPoint(CGPoint(
            x: geometry.localBounds.midX,
            y: geometry.localBounds.maxY - 8
        )))
        XCTAssertTrue(geometry.containsActiveHitPoint(CGPoint(
            x: geometry.contentRect.midX,
            y: geometry.contentRect.midY
        )))
        XCTAssertTrue(geometry.containsActiveHitPoint(CGPoint(
            x: geometry.notchPocket.minX - 12,
            y: geometry.notchPocket.midY
        )))
        XCTAssertTrue(geometry.containsActiveHitPoint(CGPoint(
            x: geometry.notchPocket.maxX + 12,
            y: geometry.notchPocket.midY
        )))
    }
}
