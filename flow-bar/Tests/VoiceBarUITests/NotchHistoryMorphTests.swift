import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 lane U4 guards: History morph B exactly as in the approved mocks (2-morph.html, 5-history.html), the 2-line
/// rows, and pulling History down from the notch. The order-of-events half (drag versus click, a close never cut
/// off, every morph reversible) is model-checked in formal/history-pull (Old and three mutants FAIL, Fixed PASS).
final class NotchHistoryMorphTests: XCTestCase {
    // MARK: Morph B values

    func testTheSpringsAndRadiiAreMorphBs() {
        XCTAssertEqual(NotchHistoryMorph.openResponse, 0.42)
        XCTAssertEqual(NotchHistoryMorph.openDampingFraction, 0.8)
        XCTAssertEqual(NotchHistoryMorph.closeResponse, 0.45)
        XCTAssertEqual(NotchHistoryMorph.closeDampingFraction, 1.0)
        XCTAssertEqual(NotchHistoryMorph.openTopRadius, 19)
        XCTAssertEqual(NotchHistoryMorph.openBottomRadius, 24)
        XCTAssertEqual(VoiceBarNotchContract.material.compactOuterCornerRadius(for: .history), 24)
    }

    /// The mock's `springParams`: k = (2π / response)², c = 4π ζ / response.
    func testSpringCoefficientsMatchTheMocksMapping() {
        let open = NotchHistoryMorph.springCoefficients(response: 0.42, dampingFraction: 0.8)
        XCTAssertEqual(open.stiffness, pow(2 * .pi / 0.42, 2), accuracy: 1e-9)
        XCTAssertEqual(open.damping, 4 * .pi * 0.8 / 0.42, accuracy: 1e-9)
        let close = NotchHistoryMorph.springCoefficients(response: 0.45, dampingFraction: 1)
        XCTAssertEqual(close.damping, 2 * sqrt(close.stiffness), accuracy: 1e-9, "close is critically damped")
    }

    func testRowsGrowOutOfTheNotch() {
        XCTAssertEqual(NotchHistoryMorph.rowsScale(progress: 0), 0.8)
        XCTAssertEqual(NotchHistoryMorph.rowsScale(progress: 1), 1)
        XCTAssertEqual(NotchHistoryMorph.rowsScale(progress: 1.06), 1, "scale is clamped through the overshoot")
        XCTAssertEqual(NotchHistoryMorph.rowsBlur(progress: 0), 20)
        XCTAssertEqual(NotchHistoryMorph.rowsBlur(progress: 0.5), 10, accuracy: 1e-9)
        XCTAssertEqual(NotchHistoryMorph.rowsBlur(progress: 1), 0, "no blur pass at all once open")
        XCTAssertEqual(NotchHistoryMorph.rowsOpacity(progress: 0.3), 0, "invisible for the first 30 %")
        XCTAssertEqual(NotchHistoryMorph.rowsOpacity(progress: 0.65), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NotchHistoryMorph.rowsOpacity(progress: 1), 1)
    }

    func testRadiiFollowProgressClamped() {
        XCTAssertEqual(NotchHistoryMorph.topRadius(progress: 0, closed: 0), 0)
        XCTAssertEqual(NotchHistoryMorph.topRadius(progress: 1.08, closed: 0), 19)
        XCTAssertEqual(NotchHistoryMorph.bottomRadius(progress: 0.5, closed: 15), 19.5, accuracy: 1e-9)
    }

    func testGeometryRunsFromTheLauncherToThePanelAndOvershootsUnclamped() {
        let closed = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let open = VoiceBarNotchContract.geometry(for: .history)
        XCTAssertEqual(NotchHistoryMorph.geometry(progress: 0, closed: closed, open: open), closed)
        XCTAssertEqual(NotchHistoryMorph.geometry(progress: 1, closed: closed, open: open), open)
        let over = NotchHistoryMorph.geometry(progress: 1.05, closed: closed, open: open)
        XCTAssertGreaterThan(over.lowerSurfaceHeight, open.lowerSurfaceHeight, "the open spring's overshoot shows")
        XCTAssertGreaterThan(over.bodyWidth, open.bodyWidth)
        XCTAssertEqual(NotchHistoryMorph.geometry(progress: -0.2, closed: closed, open: open).lowerSurfaceHeight, 0)
    }

    /// SwiftUI's initial velocity is relative to the distance left; a flick's progress-per-second is converted.
    func testReleaseVelocityIsConvertedToTheSpringsRelativeUnits() {
        XCTAssertEqual(
            NotchHistoryMorph.animation(opening: true, from: 0.5, velocity: 2),
            .interpolatingSpring(
                mass: 1,
                stiffness: pow(2 * .pi / 0.42, 2),
                damping: 4 * .pi * 0.8 / 0.42,
                initialVelocity: 4
            )
        )
    }

    // MARK: Shape

    private func shapeBounds(progress: CGFloat, core: CGFloat = 185) -> (CGRect, VoiceBarNotchGeometry) {
        let input = VoiceBarNotchHistoryMorphInput(
            progress: progress,
            closed: VoiceBarNotchContract.geometry(for: .hoverLauncher, coreWidth: core),
            open: VoiceBarNotchContract.geometry(for: .history, coreWidth: core)
        )
        let geometry = input.geometry(at: progress)
        let path = VoiceBarNotchHistoryMorphShape(morph: input, coreAnchorX: nil)
            .path(in: CGRect(x: 0, y: 0, width: 600, height: 600))
        return (path.boundingRect, geometry)
    }

    func testTheOpenPanelFlaresIntoTheMenuBarByTheTopRadius() {
        let (bounds, geometry) = shapeBounds(progress: 1)
        XCTAssertEqual(bounds.minX, geometry.topOriginX - 19, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, geometry.topOriginX + geometry.topWidth + 19, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 380, accuracy: 0.01)
    }

    func testAtZeroTheMorphIsExactlyTheLauncher() {
        let launcher = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let (bounds, _) = shapeBounds(progress: 0)
        let expected = VoiceBarNotchContinuousShape(
            geometry: launcher,
            compactOuterCornerRadius: VoiceBarNotchContract.material.compactOuterCornerRadius(for: .hoverLauncher)
        ).path(in: CGRect(x: 0, y: 0, width: 600, height: 600)).boundingRect
        XCTAssertEqual(bounds, expected)
    }

    func testOtherStatesDrawNoFlare() {
        let teleprompter = VoiceBarNotchContract.geometry(for: .teleprompter)
        let path = VoiceBarNotchContinuousShape(geometry: teleprompter, compactOuterCornerRadius: 18)
            .path(in: CGRect(x: 0, y: 0, width: teleprompter.totalWidth, height: teleprompter.totalHeight))
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
    }

    func testTheMorphCanvasHoldsTheFlaredPanelOnANarrowNotch() {
        for core in [CGFloat(150), 168, 185, 220] {
            let presentation = VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                hasHistoryPanel: true, isHovered: true, isKeyboardFocused: false, coreWidth: core
            )
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
            XCTAssertGreaterThanOrEqual(
                canvas.bodyLeadingExtent,
                presentation.geometry.bodyLeadingExtent + NotchHistoryMorph.openTopRadius,
                "@\(core)"
            )
        }
    }

    func testOnlyLauncherAndHistoryHandOffWithoutASecondSpring() {
        typealias View = VoiceBarNotchView<EmptyView, EmptyView, EmptyView>
        XCTAssertTrue(View.isHistoryPair(.hoverLauncher, .history))
        XCTAssertTrue(View.isHistoryPair(.history, .hoverLauncher))
        XCTAssertFalse(View.isHistoryPair(.history, .recording), "recording still morphs from History as before")
        XCTAssertFalse(View.isHistoryPair(.history, .history))
        XCTAssertFalse(View.isHistoryPair(nil, .history))
    }

    // MARK: Rows, scroll indicator, hover

    func testSevenTwoLineRowsAndTheMocksInsets() {
        XCTAssertEqual(NotchHistoryMorph.rowHeight, 46)
        XCTAssertEqual(NotchHistoryMorph.visibleRows, 7)
        XCTAssertEqual(NotchHistoryMorph.listTopInset, 8)
        XCTAssertEqual(NotchHistoryMorph.handleBandHeight, 18, "the mock: 40 + rows × 46 + 18")
        XCTAssertEqual(NotchHistoryMorph.lowerSurfaceHeight, 8 + 7 * 46 + 18)
        XCTAssertEqual(NotchHistoryPresentation.rowLeadingPadding, 10)
        XCTAssertEqual(NotchHistoryPresentation.rowTrailingPadding, 6)
        XCTAssertEqual(NotchHistoryPresentation.rowCornerRadius, 8)
        XCTAssertEqual(NotchHistoryPresentation.rowTextFontSize, 13)
        XCTAssertEqual(NotchHistoryPresentation.rowMetaFontSize, 11.5)
        XCTAssertEqual(NotchHistoryPresentation.rowLineSpacing, 2)
    }

    func testTheScrollThumbFollowsTheOffsetAndIsAbsentWhenEverythingFits() {
        let visible = NotchHistoryMorph.listHeight
        XCTAssertNil(NotchHistoryPresentation.scrollThumb(offset: 0, visibleHeight: visible, contentHeight: visible))
        let content = NotchHistoryMorph.rowHeight * 12
        let top = try? XCTUnwrap(NotchHistoryPresentation.scrollThumb(
            offset: 0, visibleHeight: visible, contentHeight: content
        ))
        XCTAssertEqual(top?.minY, 0)
        XCTAssertEqual(top?.height ?? 0, visible / content * visible, accuracy: 1e-9)
        let bottom = NotchHistoryPresentation.scrollThumb(
            offset: content - visible, visibleHeight: visible, contentHeight: content
        )
        XCTAssertEqual((bottom?.minY ?? 0) + (bottom?.height ?? 0), visible, accuracy: 1e-9)
        let tiny = NotchHistoryPresentation.scrollThumb(offset: 0, visibleHeight: visible, contentHeight: 50000)
        XCTAssertEqual(tiny?.height, 24, "never thinner than the mock's 24 pt minimum")
        XCTAssertEqual(NotchHistoryPresentation.scrollIndicatorLinger, 0.7)
        XCTAssertEqual(NotchHistoryPresentation.scrollIndicatorFadeIn, 0.08)
        XCTAssertEqual(NotchHistoryPresentation.scrollIndicatorFadeOut, 0.3)
    }

    func testTheHoverTrackerMapsTheyPointerToOneRow() {
        XCTAssertEqual(NotchHistoryPresentation.rowIndex(atY: 0, rowCount: 3), 0)
        XCTAssertEqual(NotchHistoryPresentation.rowIndex(atY: 45.9, rowCount: 3), 0)
        XCTAssertEqual(NotchHistoryPresentation.rowIndex(atY: 46, rowCount: 3), 1)
        XCTAssertNil(NotchHistoryPresentation.rowIndex(atY: 46 * 3, rowCount: 3))
        XCTAssertNil(NotchHistoryPresentation.rowIndex(atY: -1, rowCount: 3))
    }

    /// R0856-06: ONE container hover tracker, never a per-row `.onHover`, and no footer prose (R0856-08).
    func testThePanelUsesOneContainerHoverTrackerAndNoFooter() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/NotchHistoryPanel.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(source.components(separatedBy: ".onContinuousHover(").count - 1, 1)
        XCTAssertFalse(source.contains(".onHover {"))
        XCTAssertFalse(source.contains(".onHover("))
        XCTAssertFalse(source.contains("onOpenHistory"))
    }

    // MARK: Pull-down

    func testRubberBandStretchesPastTheEndAndNeverAboveTheNotch() {
        XCTAssertEqual(NotchHistoryMorph.rubberBand(0.4), 0.4)
        XCTAssertEqual(NotchHistoryMorph.rubberBand(-0.3), 0)
        let past = NotchHistoryMorph.rubberBand(1.5)
        XCTAssertGreaterThan(past, 1)
        XCTAssertLessThan(past, 1.1, "resisted, not followed 1:1")
        XCTAssertLessThan(NotchHistoryMorph.rubberBand(10), 1.35, "bounded")
        XCTAssertGreaterThan(NotchHistoryMorph.rubberBand(2), NotchHistoryMorph.rubberBand(1.5), "monotonic")
    }

    func testAReleaseSettlesByFlickThenByPosition() {
        XCTAssertTrue(NotchHistoryMorph.releaseTarget(progress: 0.1, velocity: 0.6), "a downward flick opens")
        XCTAssertFalse(NotchHistoryMorph.releaseTarget(progress: 0.9, velocity: -0.6), "an upward flick closes")
        XCTAssertTrue(NotchHistoryMorph.releaseTarget(progress: 0.51, velocity: 0.2))
        XCTAssertFalse(NotchHistoryMorph.releaseTarget(progress: 0.49, velocity: -0.2))
    }

    func testAPressThatNeverLeavesTheSlopIsAClickAndMovesNothing() {
        var pull = NotchHistoryPull()
        pull.press(y: 10, progress: 0, time: 0)
        XCTAssertNil(pull.move(y: 12.5, time: 0.02, range: 340), "inside the 3 pt slop")
        XCTAssertFalse(pull.isDragging)
        XCTAssertEqual(pull.release(progress: 0), .click)
        XCTAssertEqual(pull.phase, .idle)
    }

    func testADragFollowsThePointerAndSettlesAtItsReleaseSpeed() throws {
        var pull = NotchHistoryPull()
        pull.press(y: 10, progress: 0, time: 0)
        let p1 = try XCTUnwrap(pull.move(y: 44, time: 0.016, range: 340))
        XCTAssertEqual(p1, 0.1, accuracy: 1e-9, "34 pt of a 340 pt range")
        XCTAssertTrue(pull.isDragging)
        let p2 = try XCTUnwrap(pull.move(y: 112, time: 0.032, range: 340))
        XCTAssertEqual(p2, 0.3, accuracy: 1e-9)
        guard case let .settle(open, velocity) = pull.release(progress: p2) else {
            return XCTFail("a drag always settles")
        }
        XCTAssertTrue(open, "a fast pull down opens even at 30 %")
        XCTAssertLessThanOrEqual(velocity, NotchHistoryMorph.maximumReleaseVelocity)
        XCTAssertEqual(pull.release(progress: 0), .none, "it ends exactly once")
    }

    func testACancelledDragStillSettlesAtTheNearerEnd() {
        var pull = NotchHistoryPull()
        pull.press(y: 10, progress: 1, time: 0)
        _ = pull.move(y: -200, time: 0.01, range: 340)
        XCTAssertEqual(pull.release(progress: 0.3, cancelled: true), .settle(open: false, velocity: 0))
    }

    func testOnePointerOwnsThePull() {
        var pull = NotchHistoryPull()
        pull.press(y: 10, progress: 0, time: 0)
        _ = pull.move(y: 50, time: 0.01, range: 340)
        pull.press(y: 300, progress: 0.5, time: 0.02)
        XCTAssertTrue(pull.isDragging, "a second press doesn't restart the drag")
    }

    func testAPullStartsOnTheBandOnly() {
        XCTAssertTrue(NotchHistoryPull.accepts(y: 20))
        XCTAssertFalse(NotchHistoryPull.accepts(y: 200), "rows keep their clicks")
        XCTAssertFalse(NotchHistoryPull.accepts(y: 360), "the bottom edge belongs to the extend handle")
    }

    // MARK: Grabbing a moving panel (Codex review R1)

    func testTheSpringFlightTracksWhatIsDrawn() {
        let open = NotchHistorySpringFlight(from: 0, to: 1, velocity: 0, start: 10,
                                            response: NotchHistoryMorph.openResponse,
                                            dampingFraction: NotchHistoryMorph.openDampingFraction)
        XCTAssertEqual(open.value(at: 10), 0, accuracy: 1e-9, "starts where it was")
        XCTAssertEqual(open.value(at: 9), 0, accuracy: 1e-9, "never before its start")
        let mid = open.value(at: 10.1)
        XCTAssertGreaterThan(mid, 0.05)
        XCTAssertLessThan(mid, 0.95, "mid-flight is neither end: grabbing here must not jump to 1")
        let peak = stride(from: 10.0, through: 11.5, by: 0.005).map { open.value(at: $0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1, "the 0.8-damped open spring overshoots a little, as SwiftUI's does")
        XCTAssertLessThan(peak, 1.05)
        XCTAssertEqual(open.value(at: 14), 1, accuracy: 1e-4, "settles")
        // Velocity is the derivative of the value.
        let t = 10.07, h = 1e-5
        XCTAssertEqual(open.velocity(at: t), Double(open.value(at: t + h) - open.value(at: t - h)) / (2 * h), accuracy: 1e-3)

        let close = NotchHistorySpringFlight(from: 1, to: 0, velocity: 0, start: 0,
                                             response: NotchHistoryMorph.closeResponse,
                                             dampingFraction: NotchHistoryMorph.closeDampingFraction)
        let samples = stride(from: 0.0, through: 2, by: 0.01).map { close.value(at: $0) }
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "critically damped: no bounce")
        XCTAssertGreaterThanOrEqual(samples.min() ?? -1, -1e-9)
        let thrown = NotchHistorySpringFlight(from: 0.4, to: 1, velocity: 3, start: 0, response: 0.42, dampingFraction: 1.4)
        XCTAssertEqual(thrown.velocity(at: 0), 3, accuracy: 1e-9, "an overdamped spring keeps its release speed at t = 0")
        XCTAssertEqual(thrown.value(at: 6), 1, accuracy: 1e-4)
    }

    func testAGrabMidFlightContinuesFromWhatIsDrawnNotTheTarget() throws {
        var pull = NotchHistoryPull()
        // The close spring is heading to 0; the model already holds 0, the panel is drawn at 0.6.
        pull.press(y: 10, progress: 0, time: 0)
        XCTAssertNil(pull.move(y: 12, time: 0.01, range: 348, seed: 0.6), "inside the slop: nothing moves")
        let first = try XCTUnwrap(pull.move(y: 14, time: 0.02, range: 348, seed: 0.6))
        XCTAssertEqual(first, 0.6, accuracy: 1e-9, "the drag starts exactly where the panel is drawn")
        let next = try XCTUnwrap(pull.move(y: 14 + 34.8, time: 0.04, range: 348, seed: 0.1))
        XCTAssertEqual(next, 0.7, accuracy: 1e-9, "then follows the pointer from there; a later seed is ignored")
    }

    /// Codex review R2: a grab during the open spring's overshoot (1.11) or an undershoot (-0.05) must not move the
    /// panel at the hand-off; `band(seed)` used to compress 1.11 to ~1.027, a ~29 pt jump at 348 pt of travel.
    func testAGrabDuringOvershootOrUndershootHasZeroDisplacement() throws {
        for seed: CGFloat in [1.11, -0.05] {
            var pull = NotchHistoryPull()
            pull.press(y: 100, progress: 1, time: 0)
            let handoff = try XCTUnwrap(pull.move(y: 104, time: 0.02, range: 348, seed: seed))
            XCTAssertEqual(handoff, seed, accuracy: 1e-9, "\(seed): zero displacement at the slop crossing")
            let still = try XCTUnwrap(pull.move(y: 104, time: 0.03, range: 348))
            XCTAssertEqual(still, seed, accuracy: 1e-9, "\(seed): a sample at the same pointer stays put")
            let nudged = try XCTUnwrap(pull.move(y: 104 + 3.48, time: 0.04, range: 348))
            XCTAssertLessThan(abs(nudged - seed), 0.0101, "\(seed): a 3.48 pt move moves the panel at most 1 % of travel")
        }
    }

    // MARK: V6 extend handle

    func testTheHandleTakesPressesOnlyInItsBandOnTheOpenPanel() {
        let height = VoiceBarNotchContract.topHeight + NotchHistoryMorph.lowerSurfaceHeight // 380
        let centre: CGFloat = 300
        func accepts(_ x: CGFloat, _ y: CGFloat, progress: CGFloat = 1) -> Bool {
            NotchHistoryPull.acceptsHandle(
                point: CGPoint(x: x, y: y), centreX: centre, panelHeight: height, progress: progress
            )
        }
        XCTAssertTrue(accepts(300, height - 9), "the handle's centre")
        XCTAssertTrue(accepts(300 + 44, height - 1), "the edge of its 88 pt strip")
        XCTAssertFalse(accepts(300 + 50, height - 9), "beside the strip: the panel keeps the press")
        XCTAssertFalse(accepts(300, height - 30), "the last row keeps its clicks")
        XCTAssertFalse(accepts(300, height - 9, progress: 0.6), "never while the panel is still opening")
    }

    func testRowsFollowTheHandleStretchPastBothEndsAndSnapToWholeRows() {
        XCTAssertEqual(NotchHistoryMorph.rowsRubberBand(9.4, maximum: 12), 9.4)
        let past = NotchHistoryMorph.rowsRubberBand(14, maximum: 12)
        XCTAssertGreaterThan(past, 12)
        XCTAssertLessThan(past, 12.6, "at most 0.6 of a row past the end")
        let below = NotchHistoryMorph.rowsRubberBand(5, maximum: 12)
        XCTAssertLessThan(below, 7)
        XCTAssertGreaterThan(below, 6.4)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(9.4, maximum: 12), 9)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(9.6, maximum: 12), 10)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(12.5, maximum: 12), 12)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(6.6, maximum: 12), 7)
        XCTAssertEqual(NotchHistoryMorph.snappedRows(11, maximum: 9), 9, "never past the rows there are")
    }

    func testTheHandleNeverExtendsIntoEmptyRows() {
        XCTAssertEqual(NotchHistoryMorph.maximumRows(entryCount: 3), 7)
        XCTAssertEqual(NotchHistoryMorph.maximumRows(entryCount: 9), 9)
        XCTAssertEqual(NotchHistoryMorph.maximumRows(entryCount: 40), 12)
    }

    func testAHandleDragFollowsThePointerOneRowPer46Points() throws {
        var pull = NotchHistoryPull()
        pull.press(y: 380, progress: 7, time: 0)
        let band = { NotchHistoryMorph.rowsRubberBand($0, maximum: 12) }
        XCTAssertNil(pull.move(y: 382, time: 0.01, range: 46, band: band), "inside the slop: a click")
        let rows = try XCTUnwrap(pull.move(y: 380 + 92, time: 0.2, range: 46, band: band))
        XCTAssertEqual(rows, 9, accuracy: 0.001)
        guard case .settle = pull.release(progress: rows) else { return XCTFail("a drag settles") }
        pull.press(y: 380, progress: 9, time: 1)
        XCTAssertEqual(pull.release(progress: 9), .click, "a press that never moved changes nothing")
    }

    func testTheSettledRowsAreTheHitRegionAndOutliveAClose() {
        let model = VoiceBarNotchPresentationModel()
        model.setHistoryPanelOpen(true)
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight)
        model.setHistoryRows(10)
        XCTAssertEqual(
            model.presentation.geometry.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 10),
            "the hit region grows with the settled rows"
        )
        model.setHistoryPanelOpen(false)
        model.setHistoryPanelOpen(true)
        XCTAssertEqual(model.historyRows, 10, "a reopened panel keeps its height for the session")
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 10))
    }

    func testTheWindowHoldsTheTallestPanelWhileHistoryIsUp() {
        let model = VoiceBarNotchPresentationModel()
        model.setHistoryPanelOpen(true)
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        XCTAssertGreaterThanOrEqual(
            canvas.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 12),
            "dragging the handle never resizes the window under the pointer"
        )
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 7),
                       "but clicks below the seven rows still reach the app underneath")
    }

    func testTheExtendedShellFollowsTheLiveHeight() {
        let model = VoiceBarNotchPresentationModel()
        model.setHistoryPanelOpen(true)
        let open = model.presentation.geometry
        let closed = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        var morph = VoiceBarNotchHistoryMorphInput(
            progress: 1, closed: closed, open: open,
            openLowerSurfaceHeight: NotchHistoryMorph.lowerSurfaceHeight(rows: 9.5)
        )
        XCTAssertEqual(morph.geometry(at: 1).lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 9.5))
        XCTAssertEqual(morph.openExtended.lowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 9.5))
        var shape = VoiceBarNotchHistoryMorphShape(morph: morph, coreAnchorX: nil)
        shape.animatableData = AnimatablePair(1, NotchHistoryMorph.lowerSurfaceHeight(rows: 11))
        XCTAssertEqual(shape.morph.openLowerSurfaceHeight, NotchHistoryMorph.lowerSurfaceHeight(rows: 11),
                       "the handle's spring animates the shell's height")
        morph.progress = 0
        XCTAssertEqual(morph.geometry(at: 0).lowerSurfaceHeight, closed.lowerSurfaceHeight)
    }

    // MARK: V12 clipped rows, row click

    func testAClippedRowShowsItsWholeTextInATooltipAndAShortOneShowsNone() {
        XCTAssertNil(NotchHistoryPresentation.clippedTextTooltip("Ship it."))
        let long = "For History I want two lines per row and seven rows visible, and I want to pull it down to see more."
        XCTAssertEqual(NotchHistoryPresentation.clippedTextTooltip(long), long)
        XCTAssertEqual(NotchHistoryPresentation.clippedTextTooltip("Ship   it.\nNow", availableWidth: 10), "Ship it. Now")
        let huge = String(repeating: "word ", count: 400)
        let tip = try? XCTUnwrap(NotchHistoryPresentation.clippedTextTooltip(huge))
        XCTAssertEqual(tip?.count, NotchHistoryPresentation.clippedTooltipLimit)
        XCTAssertEqual(tip?.last, "…")
        XCTAssertNil(NotchHistoryPresentation.clippedTextTooltip("   "))
    }

    func testARowClickRequestsThatRecordingInTheHistoryWindow() {
        var memory = SettingsHistoryRecordingMemory()
        memory.request("/a/audio.wav")
        memory.applyPage(["/b/audio.wav", "/a/audio.wav"])
        XCTAssertEqual(memory.selectedID, "/a/audio.wav", "the clicked recording, not the newest")
        var missing = SettingsHistoryRecordingMemory()
        missing.request("/gone/audio.wav")
        missing.applyPage(["/b/audio.wav"])
        XCTAssertEqual(missing.selectedID, "/b/audio.wav", "not on the page: the newest, as before")
        let request = SettingsTabRequest(tab: .history, historyRecordingID: "/a/audio.wav", id: 1)
        XCTAssertEqual(request.historyRecordingID, "/a/audio.wav")
    }

    func testAPullHoldsThePanelsMouseEvents() {
        let model = VoiceBarNotchPresentationModel()
        XCTAssertFalse(model.isHistoryPullActive)
        model.setHistoryPullActive(true)
        XCTAssertTrue(model.isHistoryPullActive)
        let before = model.presentation
        model.setHistoryPullActive(false)
        XCTAssertEqual(model.presentation, before, "holding the pointer never changes the shell")
    }
}
