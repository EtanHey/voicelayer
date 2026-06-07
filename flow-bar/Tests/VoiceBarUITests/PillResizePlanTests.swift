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
        XCTAssertEqual(plan.frame.midY, 14, accuracy: 0.001)
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

    func testMenuBarAttachedAnchorCentersInTopMenuBarStrip() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 47, width: 1512, height: 906)
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 700, y: 953, width: 112, height: 29)
        )

        let compact = PillResizePlan.makeAnchored(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: nil,
            menuBarAttached: true,
            menuBarProfile: profile,
            topPadding: 12,
            pillSize: CGSize(width: 120, height: 30),
            from: .idle,
            to: .recording,
            padding: 4
        ).frame

        let expanded = PillResizePlan.makeAnchored(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            horizontalOffset: 0.5,
            verticalOffset: nil,
            menuBarAttached: true,
            menuBarProfile: profile,
            topPadding: 12,
            pillSize: CGSize(width: 220, height: 70),
            from: .recording,
            to: .transcribing,
            padding: 4
        ).frame

        XCTAssertEqual(compact.midX, 756, accuracy: 0.001)
        XCTAssertEqual(compact.midY, 967.5, accuracy: 0.001)
        XCTAssertEqual(expanded.midX, 756, accuracy: 0.001)
        XCTAssertEqual(expanded.midY, 967.5, accuracy: 0.001)
    }

    func testV5MenuBarAttachedNotchedPanelIsTopFlush() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let envelope = V5IslandPanelEnvelope.make(screenFrame: screenFrame)

        XCTAssertEqual(envelope.frame.minX, screenFrame.minX, accuracy: 0.001)
        XCTAssertEqual(envelope.frame.width, screenFrame.width, accuracy: 0.001)
        XCTAssertEqual(envelope.frame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(envelope.frame.height, screenFrame.height * 0.45, accuracy: 0.001)
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
