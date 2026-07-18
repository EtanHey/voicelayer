@testable import VoiceBarUI
import XCTest

@MainActor
final class VoiceBarNotchViewTests: XCTestCase {
    func testPresentationModelTreatsHoverAndKeyboardFocusAsLauncherParity() {
        var invalidationCount = 0
        let model = VoiceBarNotchPresentationModel {
            invalidationCount += 1
        }

        XCTAssertEqual(model.presentation.visualState, .idle)
        model.setHovered(true)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
        model.setKeyboardFocused(true)
        model.setHovered(false)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
        model.setKeyboardFocused(false)
        XCTAssertEqual(model.presentation.visualState, .idle)
        XCTAssertEqual(invalidationCount, 2)
    }

    func testPresentationModelUsesOneReplacementTransitionAndReducedMotion() {
        let model = VoiceBarNotchPresentationModel()
        model.setReducedMotion(true)
        model.updateOperationalEnvelope(
            hasTeleprompter: true,
            isRecording: false,
            hasCompactStatus: false
        )
        let firstID = model.activeTransition?.id
        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false
        )

        XCTAssertNotEqual(firstID, model.activeTransition?.id)
        XCTAssertEqual(model.presentation.visualState, .recording)
        XCTAssertEqual(model.motionCoordinator.shellCount, 1)
        XCTAssertTrue(model.activeTransition?.plan.steps.allSatisfy { $0.animation == .opacity } == true)
    }

    func testUnattendedReadbackDismissesAfterGraceWindow() async {
        var dismissCount = 0
        let model = VoiceBarNotchPresentationModel(
            retainedReadbackDismissDelay: .milliseconds(20)
        )

        model.updateRetainedReadback(isReadback: true, isHovered: false) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(35))

        XCTAssertEqual(dismissCount, 1)
    }

    func testHoverCancelsDismissalAndLeavingGetsFreshFullGraceWindow() async {
        var dismissCount = 0
        let model = VoiceBarNotchPresentationModel(
            retainedReadbackDismissDelay: .milliseconds(30)
        )

        model.updateRetainedReadback(isReadback: true, isHovered: false) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(15))
        model.updateRetainedReadback(isReadback: true, isHovered: true) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(dismissCount, 0)

        model.updateRetainedReadback(isReadback: true, isHovered: false) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(dismissCount, 0)
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(dismissCount, 1)
    }

    func testNonReadbackNeverSchedulesDismissal() async {
        var dismissCount = 0
        let model = VoiceBarNotchPresentationModel(
            retainedReadbackDismissDelay: .milliseconds(10)
        )

        model.updateRetainedReadback(isReadback: false, isHovered: false) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(dismissCount, 0)
    }

    func testViewContractHasOneFixedCoreTwoReusableWingsAndOptionalLowerSurface() {
        let recording = VoiceBarNotchViewDescriptor.resolve(
            presentation: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: true,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            )
        )
        let teleprompter = VoiceBarNotchViewDescriptor.resolve(
            presentation: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: true,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            )
        )

        XCTAssertEqual(recording.shellIdentity, teleprompter.shellIdentity)
        XCTAssertEqual(recording.fixedCoreCount, 1)
        XCTAssertEqual(recording.reusableWingSlotCount, 2)
        XCTAssertEqual(recording.coreEdgeVeilCount, 2)
        XCTAssertEqual(recording.lowerSurfaceCount, 0)
        XCTAssertEqual(teleprompter.lowerSurfaceCount, 1)
        XCTAssertEqual(teleprompter.coreEdgeVeilCount, 2)
        XCTAssertTrue(teleprompter.clipsContentToVisibleSurfaces)
        XCTAssertFalse(teleprompter.coreUsesMaterial)
        XCTAssertTrue(teleprompter.usesSequencedSurfaceTransitions)
        XCTAssertTrue(teleprompter.keepsHardwareCoreOutsideAnimatedSurfaces)
        XCTAssertEqual(teleprompter.accessibilityLabel, "VoiceBar teleprompter")
    }
}
