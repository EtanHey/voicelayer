import CoreGraphics
import Foundation
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class NotchGeometryTests: XCTestCase {
    // MARK: - Closed-width formula (steal-list S2)

    func testClosedWidthUsesStealListFormulaWithSeamOverdraw() {
        // screen 1512 wide, aux areas 700 / 700 → notch ≈ 112, +4 overdraw = 116.
        let w = NotchMetrics.closedWidth(
            screenWidth: 1512,
            auxTopLeftWidth: 700,
            auxTopRightWidth: 700
        )
        XCTAssertEqual(w, 1512 - 700 - 700 + 4, accuracy: 0.001)
        XCTAssertEqual(w, 116, accuracy: 0.001)
    }

    func testClosedWidthFallsBackWhenAuxAreasAreZero() {
        // A flat display reports no auxiliary top areas → fallback width, not a negative.
        let w = NotchMetrics.closedWidth(
            screenWidth: 1920,
            auxTopLeftWidth: 0,
            auxTopRightWidth: 0
        )
        XCTAssertEqual(w, NotchMetrics.fallbackWidth, accuracy: 0.001)
    }

    func testClosedWidthNeverNegative() {
        // Degenerate aux areas wider than the screen must clamp to >= 1, never negative.
        let w = NotchMetrics.closedWidth(
            screenWidth: 100,
            auxTopLeftWidth: 90,
            auxTopRightWidth: 90
        )
        XCTAssertGreaterThanOrEqual(w, 1)
    }

    // MARK: - Closed-height formula

    func testClosedHeightEqualsSafeAreaTopWhenNotched() {
        XCTAssertEqual(NotchMetrics.closedHeight(safeAreaTop: 38), 38, accuracy: 0.001)
    }

    func testClosedHeightFallsBackOnFlatDisplay() {
        XCTAssertEqual(
            NotchMetrics.closedHeight(safeAreaTop: 0),
            NotchMetrics.fallbackHeight,
            accuracy: 0.001
        )
    }

    func testIsNotchedBranch() {
        XCTAssertTrue(NotchMetrics.isNotched(safeAreaTop: 32))
        XCTAssertFalse(NotchMetrics.isNotched(safeAreaTop: 0))
    }

    // MARK: - NotchShape silhouette (steal-list S3)

    func testNotchShapeAnimatableDataRoundTrips() {
        var shape = NotchShape(topRadius: 6, bottomRadius: 14)
        XCTAssertEqual(shape.animatableData.first, 6, accuracy: 0.001)
        XCTAssertEqual(shape.animatableData.second, 14, accuracy: 0.001)
        // Driving animatableData (as SwiftUI does mid-animation) updates the radii.
        shape.animatableData = AnimatablePair(19, 24)
        XCTAssertEqual(shape.topRadius, 19, accuracy: 0.001)
        XCTAssertEqual(shape.bottomRadius, 24, accuracy: 0.001)
    }

    func testNotchShapeFlaresOutwardBeyondRect() {
        // The top corners MUST flare OUTWARD past the rect (the hardware-island "ears").
        // So the path's bounding box is wider than the input rect by ~topRadius each side.
        let rect = CGRect(x: 0, y: 0, width: 120, height: 30)
        let shape = NotchShape(topRadius: 8, bottomRadius: 14)
        let bounds = shape.path(in: rect).boundingRect
        XCTAssertLessThan(bounds.minX, rect.minX, "left ear must flare outward")
        XCTAssertGreaterThan(bounds.maxX, rect.maxX, "right ear must flare outward")
        // Outward flare ≈ topRadius on each side.
        XCTAssertEqual(bounds.minX, rect.minX - 8, accuracy: 1.0)
        XCTAssertEqual(bounds.maxX, rect.maxX + 8, accuracy: 1.0)
    }

    func testNotchShapeIsNotEmptyAndStaysWithinHeight() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 30)
        let bounds = NotchShape(topRadius: 6, bottomRadius: 14).path(in: rect).boundingRect
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.5)
        XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.5)
    }

    func testNotchShapeClampsOversizedRadiiWithoutCrashing() {
        // Radii larger than the rect must clamp, not produce NaN / inverted geometry.
        let rect = CGRect(x: 0, y: 0, width: 20, height: 10)
        let bounds = NotchShape(topRadius: 999, bottomRadius: 999).path(in: rect).boundingRect
        XCTAssertFalse(bounds.isNull)
        XCTAssertFalse(bounds.width.isNaN)
    }

    // MARK: - FunnelPanelShape (v9 headline "grows out of the notch")

    func testFunnelPanelTopIsNarrowerThanBottom() {
        // The defining v9 property: the panel narrows to the notch neck at the TOP and
        // flares OUT to full width below the shoulders. Sample the path's left/right
        // extent near the top vs near the bottom.
        let rect = CGRect(x: 0, y: 0, width: 300, height: 178)
        let shape = FunnelPanelShape(neckWidth: 128, shoulderDrop: 22, bottomRadius: 18)
        let path = shape.path(in: rect)
        // The neck (flat top) width must be ~neckWidth, far less than the full 300.
        let topProbe = path.boundingRect // full bounds are full width...
        XCTAssertEqual(topProbe.width, 300, accuracy: 1.0, "panel reaches full width below shoulders")
        // But the TOP EDGE itself is only the neck: check the path does NOT contain
        // points just inside the top corners (they're carved out by the concave shoulder).
        let leftTopCorner = CGPoint(x: 10, y: 2)
        let rightTopCorner = CGPoint(x: 290, y: 2)
        XCTAssertFalse(path.contains(leftTopCorner), "top-left must be carved by concave shoulder")
        XCTAssertFalse(path.contains(rightTopCorner), "top-right must be carved by concave shoulder")
        // ...while a point at the neck center top IS inside.
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 2)), "neck center is solid")
    }

    func testFunnelPanelIsFullWidthAtBottom() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 178)
        let path = FunnelPanelShape(neckWidth: 128, shoulderDrop: 22, bottomRadius: 18).path(in: rect)
        // Near the bottom-center the panel spans nearly the full width.
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 160)))
        XCTAssertTrue(path.contains(CGPoint(x: 280, y: 160)))
    }

    func testFunnelPanelClampsNeckToWidth() {
        // A neck wider than the panel must clamp (no negative shoulder run / crash).
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let bounds = FunnelPanelShape(neckWidth: 9999, shoulderDrop: 22, bottomRadius: 18)
            .path(in: rect).boundingRect
        XCTAssertFalse(bounds.isNull)
        XCTAssertFalse(bounds.width.isNaN)
    }
}
