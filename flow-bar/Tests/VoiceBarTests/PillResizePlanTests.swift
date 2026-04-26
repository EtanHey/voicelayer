@testable import VoiceBar
import XCTest

final class PillResizePlanTests: XCTestCase {
    func testTranscribingToSpeakingPreservesCenterAndAnimatesResize() {
        let oldFrame = CGRect(x: 100, y: 200, width: 160, height: 38)

        let plan = PillResizePlan.make(
            oldFrame: oldFrame,
            pillSize: CGSize(width: 240, height: 76),
            from: .transcribing,
            to: .speaking,
            padding: 4
        )

        XCTAssertEqual(plan.frame.midX, oldFrame.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.midY, oldFrame.midY, accuracy: 0.001)
        XCTAssertEqual(plan.frame.width, 248, accuracy: 0.001)
        XCTAssertEqual(plan.frame.height, 84, accuracy: 0.001)
        XCTAssertTrue(plan.animate)
    }

    func testIdleToRecordingPreservesCenterAndAnimatesResize() {
        let oldFrame = CGRect(x: 40, y: 60, width: 140, height: 34)

        let plan = PillResizePlan.make(
            oldFrame: oldFrame,
            pillSize: CGSize(width: 180, height: 40),
            from: .idle,
            to: .recording,
            padding: 4
        )

        XCTAssertEqual(plan.frame.midX, oldFrame.midX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.midY, oldFrame.midY, accuracy: 0.001)
        XCTAssertTrue(plan.animate)
    }
}
