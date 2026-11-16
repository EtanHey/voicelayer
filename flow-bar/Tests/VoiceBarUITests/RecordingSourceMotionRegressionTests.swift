@testable import VoiceBarUI
import XCTest

final class RecordingSourceMotionRegressionTests: XCTestCase {
    func testRecordingVisibleReplacementsKeepTheirTargetsVisible() {
        for destination in [VoiceBarNotchVisualState.compactStatus, .hoverLauncher, .history] {
            for reducedMotion in [false, true] {
                let plan = VoiceBarNotchMotionPlan.resolve(from: .recording, to: destination, reducedMotion: reducedMotion)
                XCTAssertEqual(plan.steps.map(\.component), [.wings, .panel, .content], "recording -> \(destination)")
                XCTAssertTrue(plan.steps.allSatisfy(\.targetVisible), "recording -> \(destination)")
                XCTAssertTrue(plan.preservesFixedCore)
                XCTAssertEqual(plan.fixedCoreTranslation, .zero)
                if reducedMotion {
                    XCTAssertTrue(plan.steps.allSatisfy { $0.animation == .opacity && $0.initialScale == 1 && $0.targetScale == 1 })
                }
            }
        }
    }

    func testNonRecordingSourcesMatchMainExtentRuleForEveryPair() {
        for reducedMotion in [false, true] {
            let opening = VoiceBarNotchMotionPlan.resolve(from: .idle, to: .teleprompter, reducedMotion: reducedMotion).steps
            let closing = VoiceBarNotchMotionPlan.resolve(from: .teleprompter, to: .idle, reducedMotion: reducedMotion).steps
            for source in VoiceBarNotchVisualState.allCases where source != .recording {
                for destination in VoiceBarNotchVisualState.allCases {
                    let from = VoiceBarNotchContract.geometry(for: source)
                    let to = VoiceBarNotchContract.geometry(for: destination)
                    let mainSteps: [VoiceBarNotchMotionStep] = source == destination ? []
                        : to.totalWidth * to.totalHeight >= from.totalWidth * from.totalHeight ? opening : closing
                    let expected = VoiceBarNotchMotionPlan(source: source, destination: destination, steps: mainSteps,
                                                          preservesFixedCore: true, fixedCoreTranslation: .zero)
                    XCTAssertEqual(VoiceBarNotchMotionPlan.resolve(from: source, to: destination, reducedMotion: reducedMotion),
                                   expected, "\(source) -> \(destination), reducedMotion=\(reducedMotion)")
                }
            }
        }
    }

    func testRecordingToIdleStillClosesExactlyLikeMain() {
        for reducedMotion in [false, true] {
            let plan = VoiceBarNotchMotionPlan.resolve(from: .recording, to: .idle, reducedMotion: reducedMotion)
            let closing = VoiceBarNotchMotionPlan.resolve(from: .teleprompter, to: .idle, reducedMotion: reducedMotion)
            XCTAssertEqual(plan.steps, closing.steps)
            XCTAssertTrue(plan.steps.allSatisfy { !$0.targetVisible })
            XCTAssertTrue(plan.preservesFixedCore)
            XCTAssertEqual(plan.fixedCoreTranslation, .zero)
        }
    }

    func testRecordingToTranscribingRetainsOneVisibleOutline() {
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: true, hasCompactStatus: false,
                                        recordingLeadingWingWidth: 94, recordingTrailingWingWidth: 102)
        model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
                                        compactStatusLeadingWingWidth: 73.5, compactStatusTrailingWingWidth: 73.5)
        XCTAssertEqual(model.presentation.visualState, .compactStatus)
        XCTAssertEqual(model.presentation.geometry.leadingWingWidth, 73.5)
        XCTAssertEqual(model.presentation.geometry.trailingWingWidth, 73.5)
        XCTAssertEqual(model.activeTransition?.plan.source, .recording)
        XCTAssertEqual(model.activeTransition?.plan.destination, .compactStatus)
        XCTAssertEqual(model.activeTransition?.plan.steps.map(\.component), [.wings, .panel, .content])
        XCTAssertTrue(model.activeTransition?.plan.steps.allSatisfy(\.targetVisible) == true)
        XCTAssertEqual(model.motionCoordinator.shellCount, 1)
    }
}
