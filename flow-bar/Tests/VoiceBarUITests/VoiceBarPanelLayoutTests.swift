@testable import VoiceBarUI
import XCTest

final class VoiceBarPanelLayoutTests: XCTestCase {
    func testV8NotchAddsTopFusionBandAboveVisibleBody() {
        let layout = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.topFusionRect.minY, layout.lowerBodyRect.maxY)
        XCTAssertEqual(layout.topFusionRect.height, Theme.notchFusionBandHeight)
        XCTAssertEqual(layout.panelSize.height, layout.lowerBodyRect.height + Theme.notchFusionBandHeight)
    }

    func testV8NotchHitRegionIncludesTopFusionButRejectsTransparentCorners() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: VoiceBarPresentation.readyHotkeyHint,
            padding: Theme.panelPadding
        )

        XCTAssertTrue(layout.containsActivePoint(CGPoint(
            x: layout.panelSize.width / 2,
            y: layout.panelSize.height - 1
        )))
        XCTAssertFalse(layout.containsActivePoint(CGPoint(x: 1, y: 1)))
    }

    func testCollapsedDotUsesSmallPanelEnvelope() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: true,
            previewText: nil,
            padding: Theme.panelPadding
        )

        XCTAssertLessThanOrEqual(layout.bodySize.width, 40)
        XCTAssertLessThanOrEqual(layout.bodySize.height, 40)
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

        XCTAssertGreaterThanOrEqual(layout.bodySize.width, 190)
        XCTAssertLessThanOrEqual(layout.bodySize.width, 220)
        XCTAssertLessThan(layout.bodySize.width, Theme.panelWidth)
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

        XCTAssertGreaterThanOrEqual(layout.bodySize.width, 220)
        XCTAssertLessThanOrEqual(layout.bodySize.width, 250)
        XCTAssertLessThan(layout.bodySize.width, Theme.panelWidth)
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

        XCTAssertGreaterThanOrEqual(layout.bodySize.width, 190)
        XCTAssertLessThanOrEqual(layout.bodySize.width, 205)
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

        XCTAssertGreaterThanOrEqual(accessoryLayout.bodySize.width, noAccessoryLayout.bodySize.width)
    }

    func testExpandedIdlePanelGrowsForLongerStatusWithoutUsingFullPanel() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            statusText: "Ready for the audience to see Avner.",
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThan(layout.bodySize.width, 260)
        XCTAssertLessThan(layout.bodySize.width, Theme.panelWidth)
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

        XCTAssertEqual(holdLayout.bodySize.width, lockLayout.bodySize.width)
    }

    func testTranscriptPreviewPanelGrowsOnlyToPreviewContent() {
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: "Short sentence into an input.",
            padding: Theme.panelPadding
        )

        XCTAssertLessThan(layout.bodySize.width, Theme.panelWidth)
        XCTAssertEqual(layout.bodySize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
    }

    func testTranscribingPanelIsCompactProcessingWaveformOnly() {
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            padding: Theme.panelPadding
        )

        XCTAssertLessThanOrEqual(layout.bodySize.width, 112)
        XCTAssertEqual(layout.bodySize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
    }

    func testTranscribingPanelExpandsForWarmupStatusText() {
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "Loading speech model",
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.bodySize.width, 220)
        XCTAssertLessThan(layout.bodySize.width, Theme.panelWidth)
        XCTAssertEqual(layout.bodySize.height, Theme.pillCompactHeight + (Theme.panelPadding * 2))
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

        XCTAssertEqual(recording.bodySize.width, Theme.panelWidth)
        XCTAssertEqual(loading.bodySize.width, Theme.panelWidth)
        XCTAssertEqual(success.bodySize.width, Theme.panelWidth)
    }

    func testSpeakingQueuePanelFitsQueueVisualizationChrome() {
        let layout = VoiceBarPanelLayout.make(
            mode: .speaking,
            isCollapsed: false,
            previewText: nil,
            statusText: "Speaking...",
            queueItemCount: 2,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.bodySize.width, Theme.panelWidth)
        XCTAssertEqual(layout.bodySize.height, Theme.teleprompterViewportHeight + (Theme.panelPadding * 2))
    }

    func testLongTranscriptPreviewIncludesIconAndPaddingChrome() {
        let previewText = "If we can make it that transcribing either never shows because it is just an unloading state, or shows fully."
        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: previewText,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.bodySize.width, Theme.panelWidth)
    }
}
