@testable import VoiceBarUI
import XCTest

final class PillResizePlanTests: XCTestCase {
    func testTranscribingToSpeakingPreservesBottomCenterAndAnimatesResize() {
        let oldFrame = CGRect(x: 100, y: 200, width: 160, height: 38)

        let plan = PillResizePlan.make(
            oldFrame: oldFrame,
            pillSize: CGSize(width: 240, height: 76),
            from: .transcribing,
            to: .speaking,
            padding: 4
        )

        XCTAssertEqual(plan.frame.midX, oldFrame.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.minY, oldFrame.minY, accuracy: 0.001)
        XCTAssertEqual(plan.frame.width, 248, accuracy: 0.001)
        XCTAssertEqual(plan.frame.height, 84, accuracy: 0.001)
        XCTAssertTrue(plan.animate)
    }

    func testIdleToRecordingPreservesBottomCenterWithoutAnimatingFrameDrift() {
        let oldFrame = CGRect(x: 40, y: 60, width: 140, height: 34)

        let plan = PillResizePlan.make(
            oldFrame: oldFrame,
            pillSize: CGSize(width: 180, height: 40),
            from: .idle,
            to: .recording,
            padding: 4
        )

        XCTAssertEqual(plan.frame.midX, oldFrame.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.minY, oldFrame.minY, accuracy: 0.001)
        XCTAssertFalse(plan.animate)
    }

    func testRepeatedActivationResizeCycleDoesNotMoveOrigin() {
        let anchoredFrame = CGRect(x: 300, y: 24, width: 136, height: 38)
        var frame = anchoredFrame

        for _ in 0 ..< 5 {
            frame = PillResizePlan.make(
                oldFrame: frame,
                pillSize: CGSize(width: 220, height: 54),
                from: .idle,
                to: .recording,
                padding: 4
            ).frame

            frame = PillResizePlan.make(
                oldFrame: frame,
                pillSize: CGSize(width: 136, height: 38),
                from: .recording,
                to: .idle,
                padding: 4
            ).frame
        }

        XCTAssertEqual(frame.midX, anchoredFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.minY, anchoredFrame.minY, accuracy: 0.001)
    }

    func testAnchoredResizeStartsFromSavedPosition() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)

        let plan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.8,
            verticalOffset: 0.02,
            topPadding: 12,
            pillSize: CGSize(width: 180, height: 40),
            from: .idle,
            to: .recording,
            padding: 4
        )

        XCTAssertEqual(plan.frame.midX, 800, accuracy: 0.001)
        XCTAssertEqual(plan.frame.minY, visibleFrame.minY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(plan.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visibleFrame.maxY)
    }

    func testNearBottomSavedPositionClampsExpandedTeleprompterInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 80, width: 1000, height: 700)

        let plan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: 0,
            topPadding: 12,
            pillSize: CGSize(width: 420, height: 86),
            from: .idle,
            to: .speaking,
            padding: 0
        )

        XCTAssertEqual(plan.frame.minY, visibleFrame.minY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visibleFrame.maxY)
    }

    func testExpandedTeleprompterClampsOnDisplayWithNegativeHorizontalOrigin() {
        let visibleFrame = CGRect(x: -1440, y: 25, width: 1440, height: 900)

        let leftPlan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0,
            verticalOffset: 0.5,
            topPadding: 12,
            pillSize: CGSize(width: 420, height: 86),
            from: .idle,
            to: .speaking,
            padding: 0
        )
        let rightPlan = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 1,
            verticalOffset: 0.5,
            topPadding: 12,
            pillSize: CGSize(width: 420, height: 86),
            from: .idle,
            to: .speaking,
            padding: 0
        )

        XCTAssertEqual(leftPlan.frame.minX, visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(rightPlan.frame.maxX, visibleFrame.maxX, accuracy: 0.001)
    }

    func testDefaultAnchorUsesTopCenterAndGrowsDownward() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)

        let compact = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: nil,
            topPadding: 12,
            pillSize: CGSize(width: 120, height: 30),
            from: .idle,
            to: .recording,
            padding: 4
        ).frame

        let expanded = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: nil,
            topPadding: 12,
            pillSize: CGSize(width: 220, height: 70),
            from: .recording,
            to: .transcribing,
            padding: 4
        ).frame

        XCTAssertEqual(compact.midX, 500, accuracy: 0.001)
        XCTAssertEqual(expanded.midX, 500, accuracy: 0.001)
        XCTAssertEqual(compact.maxY, 688, accuracy: 0.001)
        XCTAssertEqual(expanded.maxY, 688, accuracy: 0.001)
    }

    func testSavedVerticalPositionPreservesCenterDuringHeightChanges() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)

        let compact = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: 0.85,
            topPadding: 12,
            pillSize: CGSize(width: 120, height: 30),
            from: .idle,
            to: .recording,
            padding: 4
        ).frame

        let expanded = PillResizePlan.makeAnchored(
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: 0.85,
            topPadding: 12,
            pillSize: CGSize(width: 220, height: 70),
            from: .recording,
            to: .transcribing,
            padding: 4
        ).frame

        XCTAssertEqual(compact.midX, expanded.midX, accuracy: 0.001)
        XCTAssertEqual(compact.midY, expanded.midY, accuracy: 0.001)
    }
}
