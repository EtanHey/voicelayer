import SwiftUI
@testable import VoiceBarUI
import XCTest

final class VoiceBarHoverHysteresisTests: XCTestCase {
    @MainActor
    func testSharedPointerPathCarriesHoverFromActiveThroughRetentionToOutside() async {
        let host = PillHostingView(rootView: EmptyView())
        let expansion = CGRect(x: 20, y: 20, width: 100, height: 32)
        let retention = expansion.insetBy(dx: -12, dy: -12)
        let exitExpectation = expectation(description: "hover exit completed")
        var pointerUpdates: [CGPoint] = []
        var hoverUpdates: [Bool] = []
        host.hoverExpansionHitTestProvider = { expansion.contains($0) }
        host.hoverRetentionHitTestProvider = { retention.contains($0) }
        host.onPointerMoved = { pointerUpdates.append($0) }
        host.onHoverChanged = { hovering in
            hoverUpdates.append(hovering)
            if !hovering {
                exitExpectation.fulfill()
            }
        }

        let activePoint = CGPoint(x: 40, y: 36)
        let retentionPoint = CGPoint(x: 12, y: 36)
        let outsidePoint = CGPoint(x: 2, y: 2)
        host.handlePointerMovement(at: activePoint)
        host.handlePointerMovement(at: retentionPoint)
        host.handlePointerMovement(at: outsidePoint)
        await fulfillment(
            of: [exitExpectation],
            timeout: VoiceBarHoverHysteresis.exitDelay + 1
        )

        XCTAssertEqual(pointerUpdates, [activePoint, retentionPoint, outsidePoint])
        XCTAssertEqual(hoverUpdates, [true, false])
    }

    func testEntryIsImmediateButExitUsesEtansTwoToThreeSecondGrace() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            [.hoverChanged(true)]
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false),
            [.scheduleExit(after: 2.5)]
        )
        XCTAssertGreaterThanOrEqual(VoiceBarHoverHysteresis.exitDelay, 2.0)
        XCTAssertLessThanOrEqual(VoiceBarHoverHysteresis.exitDelay, 3.0)
        XCTAssertEqual(hysteresis.exitDelayElapsed(), [.hoverChanged(false)])
    }

    func testCoreToWingIconAndBackNeverCollapses() {
        var hysteresis = VoiceBarHoverHysteresis()

        _ = hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true)
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            []
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            [],
            "a small overshoot past a wing icon stays inside the larger collapse-out zone"
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            []
        )
        XCTAssertTrue(hysteresis.isHovering)
    }

    func testReentryDuringExitGraceCancelsThePendingCollapse() {
        var hysteresis = VoiceBarHoverHysteresis()

        _ = hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true)
        _ = hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false)
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            [.cancelExit]
        )
        XCTAssertEqual(hysteresis.exitDelayElapsed(), [])
        XCTAssertTrue(hysteresis.isHovering)
    }

    func testRetentionZoneAloneCannotSummonACollapsedSurface() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            []
        )
        XCTAssertFalse(hysteresis.isHovering)
    }

    func testActiveToRetentionToOutsideSchedulesOneExit() {
        var hysteresis = VoiceBarHoverHysteresis()

        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: true, isInsideRetentionZone: true),
            [.hoverChanged(true)]
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: true),
            []
        )
        XCTAssertEqual(
            hysteresis.update(isInsideExpansionZone: false, isInsideRetentionZone: false),
            [.scheduleExit(after: 2.5)]
        )
    }
}
