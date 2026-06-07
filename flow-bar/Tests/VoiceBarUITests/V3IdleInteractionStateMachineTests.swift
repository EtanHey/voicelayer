import CoreGraphics
@testable import VoiceBarUI
import XCTest

final class V3IdleInteractionStateMachineTests: XCTestCase {
    func testV5StateMachineTransitionsMatchSpec() {
        XCTAssertEqual(V3IslandModel.reduce(.idle, event: .hoverEnter), .hover)
        XCTAssertEqual(V3IslandModel.reduce(.hover, event: .hoverExit), .idle)
        XCTAssertEqual(V3IslandModel.reduce(.recording, event: .hoverEnter), .recording)

        XCTAssertEqual(V3IslandModel.reduce(.idle, event: .micClick), .recording)
        XCTAssertEqual(V3IslandModel.reduce(.hover, event: .micClick), .recording)
        XCTAssertEqual(V3IslandModel.reduce(.recording, event: .micClick), .transcribing)
        XCTAssertEqual(V3IslandModel.reduce(.transcribing, event: .micClick), .transcribing)
        XCTAssertEqual(V3IslandModel.reduce(.transcribing, event: .transcribeDone), .idle)

        XCTAssertEqual(V3IslandModel.reduce(.hover, event: .historyClick), .menuOpen(.history))
        XCTAssertEqual(V3IslandModel.reduce(.hover, event: .termsClick), .menuOpen(.terms))
        XCTAssertEqual(V3IslandModel.reduce(.menuOpen(.history), event: .historyClick), .menuOpen(.history))
        XCTAssertNotEqual(V3IslandModel.reduce(.menuOpen(.history), event: .historyClick), .recording)
        XCTAssertEqual(V3IslandModel.reduce(.idle, event: .grabDown(progress: 0.25)), .menuOpen(.history))
        XCTAssertEqual(V3IslandModel.reduce(.hover, event: .grabDown(progress: 0.25)), .menuOpen(.history))
        XCTAssertEqual(V3IslandModel.reduce(.menuOpen(.terms), event: .closeSheet), .idle)
    }

    func testV52FirstRenderStripHeightUsesActualPlacedScreenSafeArea() {
        let resolved = V3IslandModel.resolvedStripHeight(
            actualScreenSafeAreaTop: 44,
            visibleMenuBarHeight: 25,
            fallbackPreviewHeight: 38
        )

        XCTAssertEqual(resolved, 44)
    }

    func testV52FlatScreenStripHeightFallsBackToVisibleMenuBarHeight() {
        let resolved = V3IslandModel.resolvedStripHeight(
            actualScreenSafeAreaTop: 0,
            visibleMenuBarHeight: 25,
            fallbackPreviewHeight: 38
        )

        XCTAssertEqual(resolved, 25)
    }

    func testV52DragOpenFirstSheetRowClearsStrip() {
        let metrics = V3IslandModel.sheetMetrics(
            stripHeight: 44,
            horizontalPadding: V3Theme.menuRowHPad,
            rowVerticalPadding: V3Theme.menuRowVPad,
            firstRowTextHeight: 37
        )

        XCTAssertGreaterThanOrEqual(metrics.firstRowFrame.minY, metrics.stripFrame.maxY)
    }

    func testV51LayoutKeepsLeftSlotAndHoverButtonsOutOfHardwareNotchRect() {
        let layout = V3IslandModel.layout(
            for: .hover,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        let hardwareNotchRect = layout.hardwareNotchRect

        XCTAssertFalse(layout.micFrame.intersects(hardwareNotchRect))
        XCTAssertFalse(layout.leftSlotFrame.intersects(hardwareNotchRect))
        XCTAssertEqual(layout.buttonFrames.count, 2)
        for frame in layout.buttonFrames {
            XCTAssertFalse(frame.intersects(hardwareNotchRect), "\(frame) intersects \(hardwareNotchRect)")
        }
    }

    func testV51LayoutWidthsRemoveLipAndAddLeftEar() {
        let idle = V3IslandModel.layout(
            for: .idle,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(idle.shellFrame, CGRect(x: 0, y: 0, width: 248, height: 38))
        XCTAssertEqual(idle.visualWidth, 236)
        XCTAssertEqual(idle.micFrame.size, CGSize(width: 10, height: 10))

        let hover = V3IslandModel.layout(
            for: .hover,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(hover.shellFrame, CGRect(x: 0, y: 0, width: 338, height: 38))

        let recording = V3IslandModel.layout(
            for: .recording,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(recording.shellFrame, CGRect(x: 0, y: 0, width: 318, height: 38))
        XCTAssertGreaterThanOrEqual(recording.leftSlotFrame.width, 62)

        let transcribing = V3IslandModel.layout(
            for: .transcribing,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(transcribing.shellFrame, CGRect(x: 0, y: 0, width: 248, height: 38))
    }

    func testV51LeftSlotAndHoverIconsShareOneCenterline() {
        let hover = V3IslandModel.layout(
            for: .hover,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )

        XCTAssertEqual(hover.micFrame.midY, hover.stripContentCenterY, accuracy: 0.001)
        for frame in hover.buttonFrames {
            XCTAssertEqual(frame.midY, hover.stripContentCenterY, accuracy: 0.001)
        }

        let recording = V3IslandModel.layout(
            for: .recording,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(recording.leftSlotFrame.midY, recording.stripContentCenterY, accuracy: 0.001)
        XCTAssertEqual(recording.waveformFrame.midY, recording.stripContentCenterY, accuracy: 0.001)

        let transcribing = V3IslandModel.layout(
            for: .transcribing,
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )
        XCTAssertEqual(transcribing.spinnerFrame.midY, transcribing.stripContentCenterY, accuracy: 0.001)
    }

    func testV51MenuUsesFullViewportWidth() {
        let menu = V3IslandModel.layout(
            for: .menuOpen(.history),
            closedNotchWidth: 200,
            stripHeight: 38,
            measuredMenuHeight: 290,
            viewportWidth: 1512
        )

        XCTAssertEqual(menu.shellFrame.width, 1512)
        XCTAssertEqual(menu.visualWidth, 1512 - (2 * V3Theme.radiiExpanded.top))
        XCTAssertEqual(menu.shellFrame.height, 290)
    }

    func testV5ShapeBodyIntervalAtMidHeightCoversHardwareNotchRect() {
        for state in [V3IslandState.idle, .hover, .recording, .transcribing] {
            let layout = V3IslandModel.layout(
                for: state,
                closedNotchWidth: 200,
                stripHeight: 38,
                measuredMenuHeight: 290,
                viewportWidth: 1512
            )

            XCTAssertLessThanOrEqual(
                layout.shapeBodyIntervalAtMidHeight.lowerBound,
                layout.hardwareNotchRect.minX,
                "\(state)"
            )
            XCTAssertGreaterThanOrEqual(
                layout.shapeBodyIntervalAtMidHeight.upperBound,
                layout.hardwareNotchRect.maxX,
                "\(state)"
            )
        }
    }
}
