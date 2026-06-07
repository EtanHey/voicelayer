@testable import VoiceBarUI
import XCTest

final class V5IslandUIStateTests: XCTestCase {
    func testEveryClosePathClosesAnOpenHistorySheet() {
        for closePath in V5IslandClosePath.allCases {
            let state = V5IslandUIState()
            state.open(.history)

            state.close(closePath)

            XCTAssertNil(state.presentedMenu, "\(closePath) should close the open sheet")
            XCTAssertEqual(state.menuProgress, 0, "\(closePath) should reset menu progress")
        }
    }

    func testRecordingAndSpeakingAutoCloseSheet() {
        for mode in [VoiceMode.recording, .speaking] {
            let state = V5IslandUIState()
            state.open(.terms)

            state.handleVoiceMode(mode)

            XCTAssertNil(state.presentedMenu, "\(mode) should auto-close the sheet")
        }
    }

    func testAnchorSurfaceToggleAndPanelLifecycleResetStickyState() {
        for resetReason in V5IslandResetReason.allCases {
            let state = V5IslandUIState()
            state.open(.history)
            state.setHovering(true)
            state.updateMeasuredMenuHeight(400)

            state.reset(resetReason)

            XCTAssertNil(state.presentedMenu, "\(resetReason) should clear the sheet")
            XCTAssertFalse(state.isHovering, "\(resetReason) should clear hover")
            XCTAssertEqual(state.menuProgress, 0, "\(resetReason) should reset progress")
            XCTAssertEqual(state.measuredMenuHeight, V3Theme.previewNotchHeight + 120)
        }
    }

    func testOpeningOneMenuThenAnotherDoesNotDependOnViewLocalState() {
        let state = V5IslandUIState()

        state.open(.history)
        state.open(.terms)

        XCTAssertEqual(state.presentedMenu, .terms)
        XCTAssertEqual(state.menuProgress, 1)
    }

    func testDragProgressLivesInAppModelWithoutPresentingStickySheet() {
        let state = V5IslandUIState()

        state.setDragProgress(0.33)

        XCTAssertNil(state.presentedMenu)
        XCTAssertEqual(state.menuProgress, 0.33, accuracy: 0.001)

        state.setDragProgress(0)

        XCTAssertNil(state.presentedMenu)
        XCTAssertEqual(state.menuProgress, 0, accuracy: 0.001)
    }

    func testCloseAffordanceIsNotExclusivelyInsideHardwareNotch() {
        let layout = V3IslandModel.layout(
            for: .menuOpen(.history),
            closedNotchWidth: 214,
            stripHeight: 38,
            measuredMenuHeight: 220,
            viewportWidth: 716
        )

        XCTAssertTrue(
            V5IslandCloseAffordance.hasTouchableAreaOutsideHardwareNotch(layout: layout),
            "Close affordance must not live exclusively inside the hardware notch occlusion"
        )
    }

    func testV5WaveformSkinReusesOldListeningDynamicsWithFixedSlots() {
        let silent = V5WaveformSkinMetrics.heights(audioLevel: 0, time: 0.5)
        let quietRoom = V5WaveformSkinMetrics.heights(audioLevel: 0.55, time: 0.5)
        let active = V5WaveformSkinMetrics.heights(audioLevel: 0.8, time: 0.5)

        XCTAssertEqual(silent.count, 7)
        XCTAssertEqual(active.count, 7)
        XCTAssertEqual(silent, quietRoom)
        XCTAssertTrue(silent.allSatisfy { $0 == V5WaveformSkinMetrics.minHeight })
        XCTAssertGreaterThan(active.reduce(0, +), silent.reduce(0, +))
    }
}
