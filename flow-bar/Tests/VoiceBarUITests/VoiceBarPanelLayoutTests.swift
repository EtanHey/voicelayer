@testable import VoiceBarUI
import XCTest

final class VoiceBarPanelLayoutTests: XCTestCase {
    func testPrimaryStatesUseApprovedVisibleGeometryInsideShadowSafeWindows() {
        let cases: [(VoiceBarNotchVisualState, CGSize)] = [
            (.idle, CGSize(width: 185, height: 32)),
            (.hoverLauncher, CGSize(width: 311, height: 32)),
            (.recording, CGSize(width: 394, height: 32)),
            (.compactStatus, CGSize(width: 394, height: 32)),
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

    func testTeleprompterUsesUnionHitTestingInsteadOfItsRectangularWindowBounds() {
        let layout = VoiceBarPanelLayout.make(presentation: presentation(.teleprompter))

        XCTAssertTrue(layout.containsActiveContent(CGPoint(x: 12 + 232.5, y: 17 + 212)))
        XCTAssertTrue(layout.containsActiveContent(CGPoint(x: 12 + 10, y: 17 + 190)))
        XCTAssertFalse(layout.containsActiveContent(CGPoint(x: 12 + 10, y: 17 + 212)))
        XCTAssertFalse(layout.containsActiveContent(CGPoint(x: 12 + 455, y: 17 + 212)))
        XCTAssertFalse(layout.containsActiveContent(CGPoint(x: 2, y: 2)))
    }

    func testWindowFrameKeepsVisibleCoreCenteredOnPhysicalHousingAndFlushToScreenTop() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
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

    func testAsymmetricRecordingWingsStillKeepTheHardwareCoreAtZeroTranslation() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
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

        XCTAssertEqual(frame, CGRect(x: 704, y: 1068, width: 418, height: 49))
        XCTAssertEqual(renderedCoreMinX, screen.housingFrame.minX)
    }

    func testWiderDetectedHousingKeepsTheRenderedCoreCentered() {
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
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

            XCTAssertTrue(panelBounds.contains(layout.activeHitRect), "state=\(state)")
        }
    }

    func testHoverRetentionExtendsPastWingIconsWithoutExtendingClickInterception() {
        let layout = VoiceBarPanelLayout.make(presentation: presentation(.hoverLauncher))
        let justPastTrailingWing = CGPoint(
            x: layout.activeHitRect.maxX + 8,
            y: layout.activeHitRect.midY
        )

        XCTAssertFalse(layout.containsActiveContent(justPastTrailingWing))
        XCTAssertTrue(layout.containsHoverRetention(justPastTrailingWing))
        XCTAssertTrue(
            CGRect(origin: .zero, size: layout.panelSize)
                .contains(layout.hoverRetentionRect)
        )
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
