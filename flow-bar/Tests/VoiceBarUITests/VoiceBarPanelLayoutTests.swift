@testable import VoiceBarUI
import XCTest

final class VoiceBarPanelLayoutTests: XCTestCase {
    func testPrimaryStatesUseApprovedVisibleGeometryInsideShadowSafeWindows() {
        let cases: [(VoiceBarNotchVisualState, CGSize)] = [
            (.idle, CGSize(width: 185, height: 32)),
            (.hoverLauncher, CGSize(width: 306, height: 32)),
            (.recording, CGSize(width: 336.5, height: 32)),
            (.compactStatus, CGSize(width: 336.5, height: 32)),
            (.teleprompter, CGSize(width: 465, height: 228)),
        ]

        for (state, expectedVisibleSize) in cases {
            let layout = VoiceBarPanelLayout.make(presentation: presentation(state))

            XCTAssertEqual(layout.visibleContentRect.size, expectedVisibleSize, "state=\(state)")
            XCTAssertEqual(layout.visibleContentRect.minX, 12, "state=\(state)")
            XCTAssertEqual(layout.visibleContentRect.minY, 17, "state=\(state)")
            XCTAssertEqual(layout.panelSize.width, expectedVisibleSize.width + 24, "state=\(state)")
            XCTAssertEqual(layout.panelSize.height, expectedVisibleSize.height + 17, "state=\(state)")
        }
    }

    func testTeleprompterCapturesOnlyItsMountedBottomControls() {
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation(.teleprompter),
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                lowerControlCount: 3
            )
        )

        XCTAssertTrue(layout.containsInteractiveContent(CGPoint(x: 12 + 202.5, y: 17 + 24)))
        XCTAssertTrue(layout.containsInteractiveContent(CGPoint(x: 12 + 262.5, y: 17 + 24)))
        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: 12 + 232.5, y: 17 + 120)))
        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: 12 + 108, y: 17 + 212)))
        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(layout.containsVisibleSurface(CGPoint(x: 12 + 232.5, y: 17 + 120)))
    }

    func testWindowFrameKeepsVisibleCoreCenteredOnPhysicalHousingAndFlushToScreenTop() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation(
                .teleprompter,
                coreWidth: screen.housingFrame.width,
                visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset
            )
        )

        let windowFrame = layout.windowFrame(anchoredTo: screen)
        let visibleFrame = CGRect(
            x: windowFrame.minX + layout.visibleContentRect.minX,
            y: windowFrame.minY + layout.visibleContentRect.minY,
            width: layout.visibleContentRect.width,
            height: layout.visibleContentRect.height
        )

        XCTAssertEqual(windowFrame, CGRect(x: 627.5, y: 872, width: 472, height: 245))
        XCTAssertEqual(visibleFrame, CGRect(x: 639.5, y: 889, width: 448, height: 228))
        XCTAssertEqual(visibleFrame.midX, screen.housingFrame.midX)
        XCTAssertEqual(visibleFrame.maxY, screen.screenFrame.maxY)
    }

    func testAsymmetricRecordingWingsKeepTheHardwareCoreAtZeroTranslation() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation(
                .recording,
                coreWidth: screen.housingFrame.width,
                visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset
            )
        )

        let frame = layout.windowFrame(anchoredTo: screen)
        let renderedCoreMinX = frame.minX
            + layout.visibleContentRect.minX
            + layout.presentation.geometry.coreOriginX

        XCTAssertEqual(frame.size, layout.panelSize)
        XCTAssertEqual(frame.maxY, screen.screenFrame.maxY)
        XCTAssertEqual(renderedCoreMinX, screen.housingFrame.minX)
    }

    func testWiderDetectedHousingKeepsTheRenderedCoreCentered() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 972, y: 1085, width: 756, height: 32)
            )
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation(
                .recording,
                coreWidth: screen.housingFrame.width,
                visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset
            )
        )

        let frame = layout.windowFrame(anchoredTo: screen)
        let renderedCoreMidX = frame.minX
            + layout.visibleContentRect.minX
            + layout.presentation.geometry.coreOriginX
            + (layout.presentation.geometry.coreWidth / 2)

        XCTAssertEqual(screen.housingFrame.width, 184)
        XCTAssertEqual(renderedCoreMidX, screen.housingFrame.midX)
    }

    func testEveryStateHitBoundsStayInsideTheShadowSafeWindow() {
        for state in VoiceBarNotchVisualState.allCases {
            let layout = VoiceBarPanelLayout.make(presentation: presentation(state))
            let panelBounds = CGRect(origin: .zero, size: layout.panelSize)

            XCTAssertTrue(panelBounds.contains(layout.interactiveHitRect), "state=\(state)")
        }
    }

    func testCollapsedVirtualNotchPassesClicksThroughButKeepsItsInvisibleCatchBand() {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false,
            virtualNotchIdleCoreHeight: 24
        )
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: .none
        )
        let coreCenter = CGPoint(
            x: layout.visibleContentRect.minX + presentation.geometry.coreMidX,
            y: layout.visibleContentRect.minY + 12
        )
        let justBelowCore = CGPoint(
            x: coreCenter.x,
            y: layout.visibleContentRect.minY - 1
        )

        XCTAssertEqual(presentation.geometry.topHeight, 24)
        XCTAssertEqual(presentation.geometry.coreWidth, VoiceBarNotchContract.coreWidth)
        XCTAssertFalse(layout.containsVisibleSurface(coreCenter))
        XCTAssertFalse(layout.containsInteractiveContent(coreCenter))
        XCTAssertFalse(layout.containsVisibleSurface(justBelowCore))
        XCTAssertTrue(layout.containsHoverExpansion(coreCenter))
        XCTAssertTrue(layout.containsHoverExpansion(justBelowCore))
        XCTAssertEqual(
            layout.hoverExpansionRect,
            CGRect(
                x: layout.visibleContentRect.minX,
                y: layout.visibleContentRect.minY - 16,
                width: VoiceBarNotchContract.coreWidth,
                height: 40
            )
        )
        XCTAssertFalse(layout.containsVisibleSurface(CGPoint(x: 1, y: 1)))
    }

    func testIsolatedCapturePlacementRequiresParallelModeAndUsesANormalScreenCorner() {
        let captureOnly = [
            VoiceBarIsolatedCapturePlacement.environmentVariable: "1",
        ]
        let isolatedCapture = [
            VoiceBarIsolatedCapturePlacement.environmentVariable: "1",
            VoiceBarIsolatedCapturePlacement.parallelInstanceEnvironmentVariable: "1",
        ]

        XCTAssertFalse(VoiceBarIsolatedCapturePlacement.isEnabled(environment: captureOnly))
        XCTAssertTrue(VoiceBarIsolatedCapturePlacement.isEnabled(environment: isolatedCapture))
        XCTAssertEqual(
            VoiceBarIsolatedCapturePlacement.frame(
                panelSize: CGSize(width: 370, height: 49),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084)
            ),
            CGRect(x: 24, y: 24, width: 370, height: 49)
        )
    }

    func testExplicitTopRightQAPlacementNeverUsesTheBottomLeftAgentPaneArea() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let panelSize = CGSize(width: 472, height: 245)
        let environment = [
            VoiceBarIsolatedCapturePlacement.topRightEnvironmentVariable: "1",
            VoiceBarIsolatedCapturePlacement.parallelInstanceEnvironmentVariable: "1",
        ]

        XCTAssertTrue(VoiceBarIsolatedCapturePlacement.isEnabled(environment: environment))
        XCTAssertEqual(
            VoiceBarIsolatedCapturePlacement.frame(
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                environment: environment
            ),
            CGRect(x: 1232, y: 815, width: 472, height: 245)
        )
    }

    func testExplicitOffscreenQAPlacementRequiresParallelModeAndStaysBeyondNegativeTwentyThousand() {
        let panelSize = CGSize(width: 472, height: 245)
        let environment = [
            VoiceBarIsolatedCapturePlacement.offscreenEnvironmentVariable: "1",
            VoiceBarIsolatedCapturePlacement.parallelInstanceEnvironmentVariable: "1",
        ]

        XCTAssertTrue(VoiceBarIsolatedCapturePlacement.isEnabled(environment: environment))
        XCTAssertEqual(
            VoiceBarIsolatedCapturePlacement.frame(
                panelSize: panelSize,
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
                environment: environment
            ),
            CGRect(x: -20496, y: -20269, width: 472, height: 245)
        )
    }

    func testEveryDynamicOffscreenFrameStaysEntirelyBeyondNegativeTwentyThousand() {
        let environment = [
            VoiceBarIsolatedCapturePlacement.offscreenEnvironmentVariable: "1",
            VoiceBarIsolatedCapturePlacement.parallelInstanceEnvironmentVariable: "1",
        ]
        for state in VoiceBarNotchVisualState.allCases {
            let presentation = presentation(state)
            let layout = VoiceBarPanelLayout.make(
                presentation: presentation,
                canvasGeometry: VoiceBarNotchCanvasLayout.resolve(
                    for: presentation
                ).canvasGeometry
            )
            let frame = VoiceBarIsolatedCapturePlacement.frame(
                layout: layout,
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
                environment: environment
            )

            XCTAssertLessThanOrEqual(frame.maxX, -20000, "state=\(state)")
            XCTAssertLessThanOrEqual(frame.maxY, -20000, "state=\(state)")
        }
    }

    func testIsolatedCaptureKeepsDynamicWindowsCoreAlignedInsideOneEnvelope() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let recordingPresentation = presentation(.recording)
        let teleprompterPresentation = presentation(.teleprompter)
        let recordingLayout = VoiceBarPanelLayout.make(
            presentation: recordingPresentation,
            canvasGeometry: VoiceBarNotchCanvasLayout.resolve(
                for: recordingPresentation
            ).canvasGeometry
        )
        let teleprompterLayout = VoiceBarPanelLayout.make(
            presentation: teleprompterPresentation,
            canvasGeometry: VoiceBarNotchCanvasLayout.resolve(
                for: teleprompterPresentation
            ).canvasGeometry
        )
        let recordingFrame = VoiceBarIsolatedCapturePlacement.frame(
            layout: recordingLayout,
            visibleFrame: visibleFrame
        )
        let teleprompterFrame = VoiceBarIsolatedCapturePlacement.frame(
            layout: teleprompterLayout,
            visibleFrame: visibleFrame
        )
        let recordingCoreMidX = recordingFrame.minX
            + recordingLayout.visibleContentRect.minX
            + recordingLayout.presentation.geometry.coreMidX
        let teleprompterCoreMidX = teleprompterFrame.minX
            + teleprompterLayout.visibleContentRect.minX
            + teleprompterLayout.presentation.geometry.coreMidX

        XCTAssertEqual(recordingFrame.maxY, teleprompterFrame.maxY)
        XCTAssertEqual(recordingCoreMidX, teleprompterCoreMidX)
        XCTAssertTrue(visibleFrame.contains(recordingFrame))
        XCTAssertTrue(visibleFrame.contains(teleprompterFrame))
        XCTAssertEqual(recordingFrame.height, 49)
        XCTAssertEqual(teleprompterFrame.height, 245)
        XCTAssertFalse(
            recordingFrame.contains(
                CGPoint(x: recordingCoreMidX, y: teleprompterFrame.minY + 24)
            )
        )
        XCTAssertTrue(
            teleprompterFrame.contains(
                CGPoint(x: teleprompterCoreMidX, y: teleprompterFrame.minY + 24)
            )
        )
    }

    func testHoverExpansionAndRetentionDoNotExtendClickInterception() {
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation(.hoverLauncher),
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )
        let justPastTrailingWing = CGPoint(
            x: layout.interactiveHitRect.maxX + 8,
            y: layout.interactiveHitRect.midY
        )
        let coreCenter = CGPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreMidX,
            y: layout.visibleContentRect.minY + 16
        )

        XCTAssertFalse(layout.containsInteractiveContent(coreCenter))
        XCTAssertTrue(layout.containsHoverExpansion(coreCenter))
        XCTAssertFalse(layout.containsInteractiveContent(justPastTrailingWing))
        XCTAssertTrue(layout.containsHoverRetention(justPastTrailingWing))
        XCTAssertTrue(
            CGRect(origin: .zero, size: layout.panelSize)
                .contains(layout.hoverRetentionRect)
        )
    }

    func testEmptyInteractionConfigurationKeepsHoverExpansionOnTheCore() {
        let presentation = presentation(.compactStatus)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: .none
        )
        let expectedCoreRect = CGRect(
            x: layout.visibleContentRect.minX + presentation.geometry.coreOriginX,
            y: layout.visibleContentRect.minY + presentation.geometry.lowerSurfaceHeight,
            width: presentation.geometry.coreWidth,
            height: presentation.geometry.topHeight
        )

        XCTAssertEqual(layout.hoverExpansionRect, expectedCoreRect)
    }

    func testInstallingANewLayoutDropsOldInteractiveGeometryImmediately() {
        let presentation = presentation(.hoverLauncher)
        let launcher = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )
        let idle = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: .none
        )
        let oldDictionaryCenter = CGPoint(
            x: launcher.visibleContentRect.minX + 282,
            y: launcher.visibleContentRect.minY + 16
        )

        XCTAssertTrue(launcher.containsInteractiveContent(oldDictionaryCenter))
        XCTAssertFalse(idle.containsInteractiveContent(oldDictionaryCenter))
    }

    private func presentation(
        _ state: VoiceBarNotchVisualState,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0
    ) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: state == .teleprompter,
            isRecording: state == .recording,
            hasCompactStatus: state == .compactStatus,
            isHovered: state == .hoverLauncher,
            isKeyboardFocused: false,
            coreWidth: coreWidth,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset
        )
    }

    func testRecordingEntryModesShareTheSameRedDotInset() {
        let askMetrics = Theme.pillMetrics(
            for: .recording,
            statusText: "",
            showsRecordingHold: true
        )
        let f5Metrics = Theme.pillMetrics(
            for: .recording,
            statusText: "",
            showsRecordingHold: false
        )
        let pillPressMetrics = Theme.pillMetrics(
            for: .recording,
            statusText: "",
            showsRecordingHold: false
        )

        XCTAssertEqual(askMetrics.horizontalPadding, 10)
        XCTAssertEqual(askMetrics.horizontalPadding, f5Metrics.horizontalPadding)
        XCTAssertEqual(f5Metrics.horizontalPadding, pillPressMetrics.horizontalPadding)
        XCTAssertEqual(askMetrics.contentSpacing, f5Metrics.contentSpacing)
    }

    func testRecordingWidthHugsTheVisibleHoldControlInsteadOfCompressingPadding() {
        let askMetrics = Theme.pillMetrics(
            for: .recording,
            statusText: "",
            showsRecordingHold: true
        )
        let manualMetrics = Theme.pillMetrics(
            for: .recording,
            statusText: "",
            showsRecordingHold: false
        )

        XCTAssertEqual(
            askMetrics.width - manualMetrics.width,
            Theme.pillActionButtonSize + Theme.pillActionButtonSpacing,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            askMetrics.width - askMetrics.contentWidth,
            askMetrics.horizontalPadding * 2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            manualMetrics.width - manualMetrics.contentWidth,
            manualMetrics.horizontalPadding * 2,
            accuracy: 0.0001
        )
    }

    func testTranscribingWidthHasNoResidualTrailingSlack() {
        let metrics = Theme.pillMetrics(
            for: .transcribing,
            statusText: "Transcribing..."
        )

        XCTAssertEqual(metrics.horizontalPadding, 10)
        XCTAssertEqual(
            metrics.width - metrics.contentWidth,
            metrics.horizontalPadding * 2,
            accuracy: 0.0001
        )
        XCTAssertLessThan(metrics.width, 220)
    }

    func testTranscribingWidthRespondsToVisibleStatusContent() {
        let short = Theme.pillMetrics(
            for: .transcribing,
            statusText: "Working"
        )
        let long = Theme.pillMetrics(
            for: .transcribing,
            statusText: "Loading speech model"
        )

        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertLessThanOrEqual(long.width, Theme.panelWidth - (Theme.panelPadding * 2))
    }
}
