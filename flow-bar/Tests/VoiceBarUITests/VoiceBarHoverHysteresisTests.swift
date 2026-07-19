@testable import VoiceBarUI
import XCTest

final class VoiceBarHoverHysteresisTests: XCTestCase {
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
}
