@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchMotionTests: XCTestCase {
    func testOpeningOrdersWingsThenPanelThenContent() {
        let plan = VoiceBarNotchMotionPlan.resolve(
            from: .idle,
            to: .teleprompter,
            reducedMotion: false
        )

        XCTAssertEqual(plan.steps.map(\.component), [.wings, .panel, .content])
        XCTAssertEqual(plan.steps.map(\.delay), [0, 0.05, 0.10])
        XCTAssertTrue(plan.steps.allSatisfy(\.targetVisible))
        XCTAssertTrue(plan.preservesFixedCore)
    }

    func testClosingOrdersContentThenPanelThenWings() {
        let plan = VoiceBarNotchMotionPlan.resolve(
            from: .teleprompter,
            to: .idle,
            reducedMotion: false
        )

        XCTAssertEqual(plan.steps.map(\.component), [.content, .panel, .wings])
        for (actual, expected) in zip(plan.steps.map(\.delay), [0, 0.12, 0.17]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(plan.steps.first?.duration, 0.12)
        XCTAssertTrue(plan.steps.allSatisfy { !$0.targetVisible })
        XCTAssertTrue(plan.preservesFixedCore)
    }

    func testFixedCoreNeverAppearsInAnAnimatedComponent() {
        for source in VoiceBarNotchVisualState.allCases {
            for destination in VoiceBarNotchVisualState.allCases {
                let plan = VoiceBarNotchMotionPlan.resolve(
                    from: source,
                    to: destination,
                    reducedMotion: false
                )

                XCTAssertFalse(plan.animatedComponents.contains(.hardwareCore))
                XCTAssertEqual(plan.fixedCoreTranslation, .zero)
            }
        }
    }

    func testInterruptReplacesTheActiveTransitionWithoutStackingShells() {
        var coordinator = VoiceBarNotchMotionCoordinator(initialState: .idle)
        let first = coordinator.replaceTarget(with: .teleprompter, reducedMotion: false)
        let second = coordinator.replaceTarget(with: .recording, reducedMotion: false)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(coordinator.activeTransition?.id, second.id)
        XCTAssertEqual(coordinator.targetState, .recording)
        XCTAssertEqual(coordinator.shellCount, 1)
    }

    func testReducedMotionKeepsSemanticOrderAndNeverUsesNearZeroScale() {
        let opening = VoiceBarNotchMotionPlan.resolve(
            from: .idle,
            to: .teleprompter,
            reducedMotion: true
        )
        let closing = VoiceBarNotchMotionPlan.resolve(
            from: .teleprompter,
            to: .idle,
            reducedMotion: true
        )

        XCTAssertEqual(opening.steps.map(\.component), [.wings, .panel, .content])
        XCTAssertEqual(closing.steps.map(\.component), [.content, .panel, .wings])
        XCTAssertTrue((opening.steps + closing.steps).allSatisfy {
            $0.initialScale >= 0.96 && $0.targetScale >= 0.96
        })
        XCTAssertTrue((opening.steps + closing.steps).allSatisfy { $0.animation == .opacity })
    }
}
