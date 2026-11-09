@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchContractTests: XCTestCase {
    func testApprovedGeometryForEveryVisualState() {
        XCTAssertEqual(
            VoiceBarNotchContract.geometry(for: .idle),
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 0,
                trailingWingWidth: 0,
                bodyLeadingExtent: 0,
                bodyTrailingExtent: 0,
                lowerSurfaceHeight: 0
            )
        )
        XCTAssertEqual(
            VoiceBarNotchContract.geometry(for: .hoverLauncher),
            // 2.3 U2: both wings are the fixed 73.5 pt (mic + chevron | History + Settings).
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 73.5,
                trailingWingWidth: 73.5,
                bodyLeadingExtent: 73.5,
                bodyTrailingExtent: 73.5,
                lowerSurfaceHeight: 0
            )
        )
        XCTAssertEqual(
            VoiceBarNotchContract.geometry(for: .recording),
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 73.5,
                trailingWingWidth: 73.5,
                bodyLeadingExtent: 0,
                bodyTrailingExtent: 0,
                lowerSurfaceHeight: 0
            )
        )
        XCTAssertEqual(
            VoiceBarNotchContract.geometry(for: .teleprompter),
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 0,
                trailingWingWidth: 73.5,
                bodyLeadingExtent: 180,
                bodyTrailingExtent: 180,
                lowerSurfaceHeight: 196
            )
        )
    }

    func testDerivedGeometryMatchesTheApprovedTotals() {
        let idle = VoiceBarNotchContract.geometry(for: .idle)
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let recording = VoiceBarNotchContract.geometry(for: .recording)
        let teleprompter = VoiceBarNotchContract.geometry(for: .teleprompter)

        XCTAssertEqual(idle.topWidth, 185)
        XCTAssertEqual(idle.totalWidth, 185)
        XCTAssertEqual(idle.totalHeight, 32)
        // 2.3 U2: the outline never moves between the launcher and recording (185 + 2 × 73.5).
        XCTAssertEqual(hover.topWidth, 332)
        XCTAssertEqual(hover.totalWidth, 332)
        XCTAssertEqual(recording.topWidth, 332)
        XCTAssertEqual(recording.totalWidth, 332)
        XCTAssertEqual(teleprompter.topWidth, 258.5)
        XCTAssertEqual(teleprompter.bodyWidth, 545, "2.4: the widened teleprompter")
        XCTAssertEqual(teleprompter.totalWidth, 545)
        XCTAssertEqual(teleprompter.totalHeight, 228)
    }

    func testCompactStatesKeepOneGlassShapeWhileRecordingFitsEachWing() {
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let recording = VoiceBarNotchContract.geometry(for: .recording)
        let status = VoiceBarNotchContract.geometry(for: .compactStatus)

        XCTAssertEqual(hover.leadingWingWidth, 73.5)
        XCTAssertEqual(recording.leadingWingWidth, 73.5)
        XCTAssertEqual(recording.trailingWingWidth, 73.5)
        XCTAssertEqual(status.leadingWingWidth, 47.5)
        XCTAssertEqual(
            VoiceBarNotchContract.material.compactOuterCornerRadius(for: .hoverLauncher),
            VoiceBarNotchContract.material.compactOuterCornerRadius(for: .recording)
        )
        XCTAssertEqual(
            VoiceBarNotchContract.material.compactOuterCornerRadius(for: .compactStatus),
            VoiceBarNotchContract.material.compactOuterCornerRadius(for: .recording)
        )
    }

    func testEveryGeneralStateWingFitsItsOwnContent() {
        let material = VoiceBarNotchContract.material
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let recording = VoiceBarNotchContract.geometry(for: .recording)
        let teleprompter = VoiceBarNotchContract.geometry(for: .teleprompter)

        // 2.3 U2: the mic + chevron wing fits two controls, like History + Settings.
        XCTAssertEqual(
            hover.leadingWingWidth,
            VoiceBarNotchContract.compactContentFitWingWidth(
                contentWidth: 2 * material.compactControlSize + material.compactControlSpacing
            )
        )
        XCTAssertEqual(
            hover.trailingWingWidth,
            VoiceBarNotchContract.compactContentFitWingWidth(
                contentWidth: 2 * material.compactControlSize +
                    material.compactControlSpacing
            )
        )
        XCTAssertEqual(hover.leadingWingWidth, hover.trailingWingWidth)

        XCTAssertEqual(teleprompter.leadingWingWidth, 0)
        XCTAssertEqual(
            teleprompter.trailingWingWidth,
            VoiceBarNotchContract.teleprompterWaveformWingWidth(
                visibleCoreOcclusionInset: 0
            )
        )
        XCTAssertGreaterThan(teleprompter.trailingWingWidth, teleprompter.leadingWingWidth)

        XCTAssertEqual(recording.leadingWingWidth, VoiceBarNotchContract.recordingLeadingWingWidth)
        // 2.3 U2: six level bars fit the fixed right wing.
        XCTAssertEqual(recording.trailingWingWidth, VoiceBarNotchContract.fixedWingWidth)
        XCTAssertEqual(recording.leadingWingWidth, recording.trailingWingWidth)
    }

    func testCompactStatusOverridesPreserveIndependentContentFitWidths() {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: true,
            compactStatusLeadingWingWidth: 61,
            compactStatusTrailingWingWidth: 127,
            isHovered: false,
            isKeyboardFocused: false
        )

        XCTAssertEqual(presentation.geometry.leadingWingWidth, 61)
        XCTAssertEqual(presentation.geometry.trailingWingWidth, 127)
        XCTAssertNotEqual(
            presentation.geometry.leadingWingWidth,
            presentation.geometry.trailingWingWidth
        )
    }

    func testMaterialContractLocksFadeSafeContentAndOneSurfaceRules() {
        let material = VoiceBarNotchContract.material

        XCTAssertEqual(material.blackToGlassFadeWidth, 16)
        XCTAssertEqual(VoiceBarNotchContract.compactCoreContentInset, 13.5)
        XCTAssertEqual(material.fadeToContentGap, 8)
        XCTAssertEqual(material.outerContentInset, 8)
        XCTAssertEqual(material.compactContentInset, 14)
        XCTAssertEqual(material.leadingTeleprompterContentWidth, 50)
        XCTAssertEqual(material.trailingTeleprompterContentWidth, 46)
        XCTAssertEqual(material.inverseJoinRadius, 5)
        XCTAssertEqual(material.waveformSlotWidth, 46)
        XCTAssertEqual(material.lowerSurfaceLayerCount, 1)
        XCTAssertEqual(material.teleprompterInsetFrameCount, 0)
        XCTAssertTrue(material.compactWingsHaveOuterEdgeTreatment)
        XCTAssertFalse(material.coreUsesBackdropMaterial)
        XCTAssertEqual(material.compactOuterCornerRadius(for: .hoverLauncher), 15)
        XCTAssertEqual(material.compactOuterCornerRadius(for: .recording), 15)
        XCTAssertEqual(material.compactOuterCornerRadius(for: .compactStatus), 15)
        XCTAssertEqual(material.recordingIndicatorSpacing, 7)
        XCTAssertEqual(material.compactControlSpacing, 6)
        XCTAssertEqual(material.compactControlSize, 20)
        XCTAssertEqual(material.hardwareCoreLowerCornerRadius, 7)
        XCTAssertEqual(material.teleprompterBodyHorizontalInset, 14)
        XCTAssertEqual(material.teleprompterTextInnerInset, 4)
        XCTAssertGreaterThanOrEqual(material.teleprompterTextFillRatio, 0.90)
        XCTAssertLessThanOrEqual(material.teleprompterTextFillRatio, 0.95)
    }

    func testCompactStatesShareOneCoreGutterAndCoreFacingSlotGeometry() {
        let material = VoiceBarNotchContract.material

        for state in [VoiceBarNotchVisualState.hoverLauncher] {
            let leading = material.wingContentLayout(for: .leading, state: state)
            let trailing = material.wingContentLayout(for: .trailing, state: state)

            XCTAssertEqual(leading.coreInset, 13.5)
            XCTAssertEqual(trailing.coreInset, 13.5)
            XCTAssertEqual(leading.outerInset, 14)
            XCTAssertEqual(trailing.outerInset, 14)
            XCTAssertEqual(leading.alignment, .center)
            XCTAssertEqual(trailing.alignment, .center)
        }

        for state in [VoiceBarNotchVisualState.recording, .compactStatus] {
            let leading = material.wingContentLayout(for: .leading, state: state)
            let trailing = material.wingContentLayout(for: .trailing, state: state)

            XCTAssertEqual(leading.coreInset, 13.5)
            XCTAssertEqual(leading.outerInset, 14)
            // 2.3 U2: the fixed right wing centres its content between equal 8 pt insets.
            XCTAssertEqual(trailing.coreInset, VoiceBarNotchContract.fixedWingContentInset)
            XCTAssertEqual(trailing.outerInset, VoiceBarNotchContract.fixedWingContentInset)
        }

        let teleprompter = material.wingContentLayout(
            for: .leading,
            state: .teleprompter
        )
        // P16: the teleprompter's leading wing (pause/play) uses the idle-hover mic's lane.
        XCTAssertEqual(teleprompter, material.wingContentLayout(for: .leading, state: .hoverLauncher))
        XCTAssertEqual(teleprompter.alignment, .center)
    }

    func testHardwareCompactContentDoesNotDoubleCountTheCalibratedBezel() {
        let material = VoiceBarNotchContract.material
        for state in [VoiceBarNotchVisualState.compactStatus, .teleprompter] {
            let layout = material.wingContentLayout(for: .trailing, state: state, visibleCoreOcclusionInset: 8.5)
            XCTAssertEqual(layout.coreInset, VoiceBarNotchContract.fixedWingContentInset, "\(state)")
            XCTAssertEqual(layout.outerInset, VoiceBarNotchContract.fixedWingContentInset, "\(state)")
            XCTAssertEqual(layout.alignment, .center)
        }
        // 2.3 N1 (Etan's real M4, 2026-11-08): the recording time sat under the physical notch, so the recording right
        // wing's content starts past the glass-hidden inset, 8 pt clear of the real notch edge.
        let recording = material.wingContentLayout(for: .trailing, state: .recording, visibleCoreOcclusionInset: 8.5)
        XCTAssertEqual(recording.coreInset, 8.5 + VoiceBarNotchContract.fixedWingContentInset)
        XCTAssertEqual(recording.outerInset, VoiceBarNotchContract.fixedWingContentInset)
    }

    func testTeleprompterTextWidthTracksTheMeasuredHardwareCoreWidth() {
        let material = VoiceBarNotchContract.material
        let narrowCoreWidth: CGFloat = 165
        let wideCoreWidth: CGFloat = 201

        XCTAssertEqual(
            material.teleprompterTextWidth(coreWidth: narrowCoreWidth),
            VoiceBarNotchContract.geometry(
                for: .teleprompter,
                coreWidth: narrowCoreWidth
            ).bodyWidth - 2 * (
                material.teleprompterBodyHorizontalInset +
                    material.teleprompterTextInnerInset
            )
        )
        XCTAssertGreaterThan(
            material.teleprompterTextWidth(coreWidth: wideCoreWidth),
            material.teleprompterTextWidth(coreWidth: narrowCoreWidth)
        )
        XCTAssertGreaterThanOrEqual(
            material.teleprompterTextFillRatio(coreWidth: narrowCoreWidth),
            0.90
        )
        XCTAssertLessThanOrEqual(
            material.teleprompterTextFillRatio(coreWidth: wideCoreWidth),
            0.95
        )
    }

    func testMotionContractLocksTheApprovedSpringAndDelays() {
        let motion = VoiceBarNotchContract.motion

        XCTAssertEqual(motion.stiffness, 310)
        XCTAssertEqual(motion.damping, 31)
        XCTAssertEqual(motion.mass, 0.72)
        XCTAssertEqual(motion.bounce, 0)
        XCTAssertEqual(motion.panelDelay, 0.05)
        XCTAssertEqual(motion.contentExitDuration, 0.12)
    }

    func testPresentationPrecedenceIsTeleprompterRecordingStatusHoverIdle() {
        XCTAssertEqual(
            VoiceBarNotchPresentation.resolve(
                hasTeleprompter: true,
                isRecording: true,
                hasCompactStatus: true,
                isHovered: true,
                isKeyboardFocused: true
            ).visualState,
            .teleprompter
        )
        XCTAssertEqual(
            VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: true,
                hasCompactStatus: true,
                isHovered: true,
                isKeyboardFocused: true
            ).visualState,
            .recording
        )
        XCTAssertEqual(
            VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: false,
                hasCompactStatus: true,
                isHovered: true,
                isKeyboardFocused: true
            ).visualState,
            .compactStatus
        )
        XCTAssertEqual(
            VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: true
            ).visualState,
            .hoverLauncher
        )
        XCTAssertEqual(
            VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            ).visualState,
            .idle
        )
    }

    func testPresentationCarriesGeometryRolesAndAccessibilityWithoutOperationalState() {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: true,
            isKeyboardFocused: false
        )

        XCTAssertEqual(presentation.geometry.totalWidth, 332)
        XCTAssertEqual(presentation.contentRoles, [.microphone, .history, .dictionary])
        XCTAssertEqual(presentation.accessibilityLabel, "VoiceBar launcher")
    }

    func testBootStatusKeepsSafetyInsetInsideStableCanvasCapacity() {
        let text = "VoiceLayer is starting"
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .error,
                statusText: text,
                isCollapsed: false
            )
        )
        let material = VoiceBarNotchContract.material
        let standardContentFit = VoiceBarNotchContract.compactCoreContentInset +
            material.compactContentInset +
            Theme.intrinsicPillStatusWidth(for: text) +
            3 +
            material.compactControlSize

        XCTAssertEqual(
            presentation.geometry.trailingWingWidth,
            min(
                standardContentFit + VoiceBarNotchContract.compactStatusTrailingSafetyInset,
                VoiceBarNotchContract.morphCanvasWingCapacity
            )
        )
    }

    func testDictionaryRoleExistsOnlyInTheHoverLauncher() {
        let states: [VoiceBarNotchVisualState] = [
            .idle, .recording, .compactStatus, .teleprompter,
        ]

        for visualState in states {
            let presentation = VoiceBarNotchPresentation.resolve(
                hasTeleprompter: visualState == .teleprompter,
                isRecording: visualState == .recording,
                hasCompactStatus: visualState == .compactStatus,
                isHovered: false,
                isKeyboardFocused: false
            )
            XCTAssertFalse(presentation.contentRoles.contains(.history), "\(visualState)")
            XCTAssertFalse(presentation.contentRoles.contains(.dictionary), "\(visualState)")
        }

        let launcher = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: true,
            isKeyboardFocused: false
        )
        XCTAssertTrue(launcher.contentRoles.contains(.dictionary))
    }
}
