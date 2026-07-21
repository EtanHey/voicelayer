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
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 47.5,
                trailingWingWidth: 73.5,
                bodyLeadingExtent: 0,
                bodyTrailingExtent: 0,
                lowerSurfaceHeight: 0
            )
        )
        XCTAssertEqual(
            VoiceBarNotchContract.geometry(for: .recording),
            VoiceBarNotchGeometry(
                coreWidth: 185,
                topHeight: 32,
                leadingWingWidth: 141.5,
                trailingWingWidth: 141.5,
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
                leadingWingWidth: 82,
                trailingWingWidth: 94,
                bodyLeadingExtent: 140,
                bodyTrailingExtent: 140,
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
        XCTAssertEqual(hover.topWidth, 306)
        XCTAssertEqual(hover.totalWidth, 306)
        XCTAssertEqual(recording.topWidth, 468)
        XCTAssertEqual(recording.totalWidth, 468)
        XCTAssertEqual(teleprompter.topWidth, 361)
        XCTAssertEqual(teleprompter.bodyWidth, 465)
        XCTAssertEqual(teleprompter.totalWidth, 465)
        XCTAssertEqual(teleprompter.totalHeight, 228)
    }

    func testCompactStatesKeepOneGlassShapeWhileRecordingBalancesItsWings() {
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let recording = VoiceBarNotchContract.geometry(for: .recording)
        let status = VoiceBarNotchContract.geometry(for: .compactStatus)

        XCTAssertEqual(hover.leadingWingWidth, 47.5)
        XCTAssertEqual(recording.leadingWingWidth, recording.trailingWingWidth)
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

    func testGeneralStateWingsFitTheirOwnContentWhileRecordingAloneIsSymmetric() {
        let material = VoiceBarNotchContract.material
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let recording = VoiceBarNotchContract.geometry(for: .recording)
        let teleprompter = VoiceBarNotchContract.geometry(for: .teleprompter)

        XCTAssertEqual(
            hover.leadingWingWidth,
            VoiceBarNotchContract.compactContentFitWingWidth(
                contentWidth: material.compactControlSize
            )
        )
        XCTAssertEqual(
            hover.trailingWingWidth,
            VoiceBarNotchContract.compactContentFitWingWidth(
                contentWidth: 2 * material.compactControlSize +
                    material.compactControlSpacing
            )
        )
        XCTAssertNotEqual(hover.leadingWingWidth, hover.trailingWingWidth)

        XCTAssertEqual(
            teleprompter.leadingWingWidth,
            VoiceBarNotchContract.teleprompterContentFitWingWidth(
                contentWidth: VoiceBarNotchContract.teleprompterLeadingContentWidth
            )
        )
        XCTAssertEqual(
            teleprompter.trailingWingWidth,
            VoiceBarNotchContract.teleprompterContentFitWingWidth(
                contentWidth: VoiceBarNotchContract.teleprompterTrailingContentWidth
            )
        )
        XCTAssertNotEqual(teleprompter.leadingWingWidth, teleprompter.trailingWingWidth)

        XCTAssertEqual(recording.leadingWingWidth, recording.trailingWingWidth)
    }

    func testCompactStatusOverridesPreserveIndependentContentFitWidths() {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: true,
            compactStatusLeadingWingWidth: 61,
            compactStatusTrailingWingWidth: 137,
            isHovered: false,
            isKeyboardFocused: false
        )

        XCTAssertEqual(presentation.geometry.leadingWingWidth, 61)
        XCTAssertEqual(presentation.geometry.trailingWingWidth, 137)
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
        XCTAssertEqual(material.trailingTeleprompterContentWidth, 62)
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

        for state in [
            VoiceBarNotchVisualState.hoverLauncher,
            .recording,
            .compactStatus,
        ] {
            let leading = material.wingContentLayout(for: .leading, state: state)
            let trailing = material.wingContentLayout(for: .trailing, state: state)

            XCTAssertEqual(leading.coreInset, 13.5)
            XCTAssertEqual(trailing.coreInset, 13.5)
            XCTAssertEqual(leading.outerInset, 14)
            XCTAssertEqual(trailing.outerInset, 14)
            XCTAssertEqual(leading.alignment, .center)
            XCTAssertEqual(trailing.alignment, .center)
        }

        let teleprompter = material.wingContentLayout(
            for: .leading,
            state: .teleprompter
        )
        XCTAssertEqual(teleprompter.coreInset, 24)
        XCTAssertEqual(teleprompter.alignment, .center)
    }

    func testHardwareCompactContentDoesNotDoubleCountTheCalibratedBezel() {
        let material = VoiceBarNotchContract.material
        let layout = material.wingContentLayout(
            for: .trailing,
            state: .recording,
            visibleCoreOcclusionInset: 8.5
        )

        XCTAssertEqual(layout.coreInset, 13.5)
        XCTAssertEqual(layout.outerInset, 14)
        XCTAssertEqual(layout.alignment, .center)
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

        XCTAssertEqual(presentation.geometry.totalWidth, 306)
        XCTAssertEqual(presentation.contentRoles, [.microphone, .history, .dictionary])
        XCTAssertEqual(presentation.accessibilityLabel, "VoiceBar launcher")
    }

    func testBootStatusReservesEightPointsBeyondStandardTrailingContentFit() {
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

        XCTAssertEqual(presentation.geometry.trailingWingWidth, standardContentFit + 8)
    }

    func testManagementRolesExistOnlyInTheHoveredLauncher() {
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
    }
}
