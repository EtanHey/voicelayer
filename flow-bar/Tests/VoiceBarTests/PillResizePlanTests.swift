@testable import VoiceBar
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

    func testIdleToRecordingPreservesBottomCenterAndAnimatesResize() {
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
        XCTAssertTrue(plan.animate)
    }

    func testRepeatedActivationResizeCycleDoesNotAccumulateLeftOrUpDrift() {
        let anchoredFrame = CGRect(x: 300, y: 24, width: 136, height: 38)
        var frame = anchoredFrame

        for _ in 0..<5 {
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
}
