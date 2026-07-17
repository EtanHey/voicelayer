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

    func testTranscribingPanelShowsFallbackLabel() {
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "Transcribing...",
            padding: Theme.panelPadding
        )

        XCTAssertGreaterThanOrEqual(layout.panelSize.width, 212)
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

    func testVADHoldControlAddsOneButtonWithoutGrowingPTT() {
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

        XCTAssertEqual(vad.panelSize.width - ptt.panelSize.width, 28)
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
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, Theme.panelWidth)
        XCTAssertEqual(Theme.speakingTeleprompterAvailableWidth, 254, accuracy: 0.001)
        XCTAssertLessThanOrEqual(Theme.teleprompterViewportWidth, Theme.speakingTeleprompterAvailableWidth)
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
}
