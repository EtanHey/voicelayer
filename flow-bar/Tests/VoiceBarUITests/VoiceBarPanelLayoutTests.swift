import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceBarPanelLayoutTests: XCTestCase {
    func testCollapsedDotUsesSmallPanelEnvelope() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: true,
            previewText: nil,
            padding: Theme.panelPadding
        )

        XCTAssertLessThanOrEqual(layout.panelSize.width, 30)
        XCTAssertLessThanOrEqual(layout.panelSize.height, 30)
    }

    func testActiveHitRectStaysInsideSmallCollapsedPanel() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: true,
            previewText: nil,
            padding: Theme.panelPadding
        )

        XCTAssertTrue(CGRect(origin: .zero, size: layout.panelSize).contains(layout.activeHitRect))
        XCTAssertLessThan(layout.activeHitRect.width, Theme.pillCompactWidth)
        XCTAssertLessThan(layout.activeHitRect.height, Theme.pillCompactHeight)
    }

    func testExpandedIdlePanelFitsHotkeyHintAndAccessoryButtons() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: VoiceBarPresentation.readyHotkeyHint,
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.panelSize.width, 190)
        XCTAssertLessThanOrEqual(layout.panelSize.width, 220)
        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
    }

    func testExpandedIdlePanelIncludesVisibleAccessoryButtonsInWidth() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: VoiceBarPresentation.readyHotkeyHint,
            idleAccessoryButtonCount: 3,
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.panelSize.width, 220)
        XCTAssertLessThanOrEqual(layout.panelSize.width, 250)
        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
    }

    func testExpandedIdlePanelWithTwoAccessoryButtonsDoesNotReserveEmptyRightRail() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: VoiceBarPresentation.readyHotkeyHint,
            idleAccessoryButtonCount: 2,
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.panelSize.width, 190)
        XCTAssertLessThanOrEqual(layout.panelSize.width, 205)
    }

    func testExpandedIdlePanelAccessoriesNeverShrinkEmptyStatusBelowBaseMinimum() {
        let noAccessoryLayout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            idleAccessoryButtonCount: 0,
            padding: Theme.panelPadding
        )
        let accessoryLayout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            idleAccessoryButtonCount: 1,
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(accessoryLayout.panelSize.width, noAccessoryLayout.panelSize.width)
    }

    func testExpandedIdlePanelGrowsForLongerStatusWithoutUsingFullPanel() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "Ready for the audience to see Avner.",
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThan(layout.panelSize.width, 260)
        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
    }

    func testHotkeyTransitionHintsReserveSamePanelWidth() {
        let holdLayout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "Hold to talk",
            padding: Theme.panelPadding
        )
        let lockLayout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "Tap again to lock",
            padding: Theme.panelPadding
        )

        XCTAssertEqual(holdLayout.panelSize.width, lockLayout.panelSize.width)
    }

    func testTranscriptPreviewPanelGrowsOnlyToPreviewContent() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: "Short sentence into an input.",
            padding: Theme.panelPadding
        )

        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(layout.panelSize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
    }

    func testTranscribingPanelMatchesTheCompactAcceptedReferenceWidth() {
        let statusText = "Transcribing..."
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: statusText,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(
            layout.panelSize.width,
            Theme.transcribingPillWidth(for: statusText) + (Theme.panelPadding * 2),
            accuracy: 0.0001
        )
        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(layout.panelSize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
    }

    func testTranscribingPanelExpandsForWarmupStatusText() {
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "Loading speech model",
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.panelSize.width, 220)
        XCTAssertLessThan(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(layout.panelSize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
    }

    func testLongTranscribingStatusFitsItsRenderedOneLineSurfaceWithoutClipping() {
        let statusText = "Transcribing long recording with local model"
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let renderedTextWidth = ceil(
            (statusText as NSString).size(withAttributes: [.font: font]).width
        )
        let visibleChromeWidth = Theme.pillProcessingSpinnerWidth + Theme.pillWaveformWidth +
            Theme.pillActionButtonSize + (8 * 3)
        let requiredPillWidth = renderedTextWidth + visibleChromeWidth + 20

        XCTAssertLessThan(requiredPillWidth, Theme.panelWidth - (Theme.panelPadding * 2))

        let metrics = Theme.pillMetrics(
            for: .transcribing,
            statusText: statusText
        )
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: statusText,
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(metrics.width, requiredPillWidth)
        XCTAssertGreaterThanOrEqual(
            layout.panelSize.width,
            requiredPillWidth + (Theme.panelPadding * 2)
        )
    }

    func testPasteFlowKeepsFixedPanelWidthAcrossRecordingLoadingAndSuccess() {
        let recording = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            isPasteFlowActive: true,
            padding: Theme.panelPadding
        )
        let loading = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            isPasteFlowActive: true,
            padding: Theme.panelPadding
        )
        let success = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: "this landed in the target input",
            statusText: "this landed in the target input",
            isPasteFlowActive: true,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(recording.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(loading.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(success.panelSize.width, Theme.panelWidth)
    }

    func testRecordingPanelHugsTheVisibleVADHoldControl() {
        let vad = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            showsRecordingHold: true,
            padding: Theme.panelPadding
        )
        let ptt = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            showsRecordingHold: false,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(
            vad.panelSize.width - ptt.panelSize.width,
            Theme.pillActionButtonSize + Theme.pillActionButtonSpacing,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(vad.panelSize.width, ptt.panelSize.width)
    }

    func testSpeakingQueuePanelFitsQueueVisualizationChrome() {
        let layout = VoiceBarPanelLayout.make(
            mode: .speaking,
            isCollapsed: false,
            previewText: nil,
            statusText: "Speaking...",
            queueItemCount: 2,
            showsTeleprompter: true,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(layout.panelSize.height, Theme.teleprompterViewportHeight + (Theme.panelPadding * 2))
    }

    func testSpeakingTeleprompterPanelUsesFullPanelEnvelope() {
        let layout = VoiceBarPanelLayout.make(
            mode: .speaking,
            isCollapsed: false,
            previewText: nil,
            statusText: "A long spoken sentence should wrap inside the teleprompter instead of clipping.",
            queueItemCount: 1,
            showsTeleprompter: true,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(Theme.speakingTeleprompterAvailableWidth, 254, accuracy: 0.001)
        XCTAssertLessThanOrEqual(Theme.teleprompterViewportWidth, Theme.speakingTeleprompterAvailableWidth)
    }

    func testHiddenSpeakingTeleprompterUsesCompactHeight() {
        let layout = VoiceBarPanelLayout.make(
            mode: .speaking,
            isCollapsed: false,
            previewText: nil,
            statusText: "Speaking...",
            showsTeleprompter: false,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(
            layout.panelSize.height,
            Theme.pillCompactHeight + (Theme.panelPadding * 2)
        )
    }

    func testIdleReadbackTeleprompterExpandsPanelForFiveAccessoryButtons() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "Ready",
            idleAccessoryButtonCount: 5,
            showsTeleprompter: true,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, 450)
        XCTAssertGreaterThan(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(
            layout.panelSize.height,
            Theme.teleprompterViewportHeight + (Theme.panelPadding * 2)
        )
    }

    func testLongTranscriptPreviewIncludesIconAndPaddingChrome() {
        let previewText = "If we can make it that transcribing either never shows because it is just an unloading state, or shows fully."
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: previewText,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, Theme.panelWidth)
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
