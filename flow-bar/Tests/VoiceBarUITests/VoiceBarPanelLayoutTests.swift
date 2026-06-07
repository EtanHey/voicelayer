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

        XCTAssertLessThanOrEqual(layout.panelSize.width, 40)
        XCTAssertLessThanOrEqual(layout.panelSize.height, 40)
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

    func testMenuBarIslandLayoutUsesNativeStripEnvelope() {
        let notchedProfile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 771, y: 1085, width: 185, height: 32)
        )
        let disconnected = VoiceBarPanelLayout.make(
            mode: .disconnected,
            isCollapsed: false,
            previewText: nil,
            surfaceStyle: .menuBarIsland,
            menuBarProfile: notchedProfile,
            padding: Theme.panelPadding
        )
        let recording = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            surfaceStyle: .menuBarIsland,
            menuBarProfile: notchedProfile,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(disconnected.panelSize.width, 185)
        XCTAssertEqual(disconnected.panelSize.height, 32)
        XCTAssertEqual(recording.panelSize.width, 285)
        XCTAssertEqual(recording.panelSize.height, 32)
        XCTAssertLessThan(recording.panelSize.height, Theme.pillCompactHeight)
    }

    func testMenuBarTranscriptMenuLayoutGrowsDownFromFullHeightIsland() {
        let notchedProfile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 771, y: 1085, width: 185, height: 32)
        )

        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            isTranscriptMenuPresented: true,
            surfaceStyle: .menuBarIsland,
            menuBarProfile: notchedProfile,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, Theme.menuBarTranscriptMenuWidth)
        XCTAssertEqual(layout.panelSize.height, 32 + Theme.menuBarTranscriptMenuHeight)
    }

    func testV5IslandOpenSheetUsesMeasuredAppStateHeight() {
        let notchedProfile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 771, y: 1085, width: 185, height: 32)
        )

        let layout = VoiceBarPanelLayout.make(
            mode: .idle,
            isCollapsed: false,
            previewText: nil,
            isTranscriptMenuPresented: true,
            v5MeasuredMenuHeight: 372,
            surfaceStyle: .v5Island,
            menuBarProfile: notchedProfile,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(layout.panelSize.width, 716)
        XCTAssertEqual(layout.panelSize.height, 372)
    }

    func testV5IslandUsesFixedViewportEnvelopeAcrossClosedStates() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let idle = V5IslandPanelEnvelope.make(screenFrame: screenFrame)
        let hover = V5IslandPanelEnvelope.make(screenFrame: screenFrame)
        let recording = V5IslandPanelEnvelope.make(screenFrame: screenFrame)

        XCTAssertEqual(idle.frame, hover.frame)
        XCTAssertEqual(hover.frame, recording.frame)
        XCTAssertEqual(recording.frame.width, screenFrame.width, accuracy: 0.001)
        XCTAssertEqual(recording.frame.maxY, screenFrame.maxY, accuracy: 0.001)
    }

    func testV5IslandClosedHitRectCentersOnEnvelopeInsteadOfSavedPillOffset() {
        let screenWidth: CGFloat = 1728
        let hitRect = V5IslandPanelEnvelope.activeHitRect(
            screenWidth: screenWidth,
            notchWidth: 237,
            stripHeight: 32,
            maxShellHeight: 502,
            isMenuPresented: false,
            measuredMenuHeight: 400
        )

        XCTAssertEqual(hitRect.midX, screenWidth / 2, accuracy: 0.001)
        XCTAssertEqual(hitRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(hitRect.height, 32, accuracy: 0.001)
    }

    func testV5IdleEnvelopePassesThroughClicksAwayFromVisibleIsland() {
        let screenWidth: CGFloat = 1728
        let hitRect = V5IslandPanelEnvelope.activeHitRect(
            screenWidth: screenWidth,
            notchWidth: 237,
            stripHeight: 32,
            maxShellHeight: 502,
            isMenuPresented: false,
            measuredMenuHeight: 400
        )

        XCTAssertFalse(hitRect.contains(CGPoint(x: screenWidth / 2, y: 300)))
        XCTAssertFalse(hitRect.contains(CGPoint(x: screenWidth * 0.25, y: 300)))
        XCTAssertFalse(hitRect.contains(CGPoint(x: screenWidth * 0.75, y: 300)))
    }

    func testV5OpenSheetHitRectDoesNotBlockBesideTheSheet() {
        let screenWidth: CGFloat = 1728
        let hitRect = V5IslandPanelEnvelope.activeHitRect(
            screenWidth: screenWidth,
            notchWidth: 237,
            stripHeight: 32,
            maxShellHeight: 502,
            isMenuPresented: true,
            measuredMenuHeight: 400
        )

        XCTAssertTrue(hitRect.contains(CGPoint(x: screenWidth / 2, y: 300)))
        XCTAssertFalse(hitRect.contains(CGPoint(x: screenWidth * 0.25, y: 300)))
        XCTAssertFalse(hitRect.contains(CGPoint(x: screenWidth * 0.75, y: 300)))
    }

    func testV5IslandSheetHeightClampsRealDictionarySizedContentToFortyFivePercentScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let envelope = V5IslandPanelEnvelope.make(screenFrame: screenFrame)

        let clamped = V5IslandPanelEnvelope.clampedShellHeight(
            measuredMenuHeight: 2400,
            stripHeight: 32,
            maxShellHeight: envelope.maxShellHeight,
            isMenuPresented: true
        )

        XCTAssertEqual(clamped, screenFrame.height * 0.45, accuracy: 0.001)
    }

    func testFlatMenuBarIslandUsesWiderPillThanNotchedDisplay() {
        let notchedProfile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 771, y: 1085, width: 185, height: 32)
        )
        let notched = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            surfaceStyle: .menuBarIsland,
            menuBarProfile: notchedProfile,
            padding: Theme.panelPadding
        )
        let flat = VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            surfaceStyle: .menuBarIsland,
            menuBarProfile: .flat,
            padding: Theme.panelPadding
        )

        XCTAssertEqual(flat.panelSize.width, Theme.menuBarIslandFlatActiveWidth)
        XCTAssertGreaterThan(flat.panelSize.width, notched.panelSize.width)
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

    func testTranscribingPanelIsCompactProcessingWaveformOnly() {
        let layout = VoiceBarPanelLayout.make(
            mode: .transcribing,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            padding: Theme.panelPadding
        )

        XCTAssertLessThanOrEqual(layout.panelSize.width, 112)
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
