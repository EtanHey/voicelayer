import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-2 (UX pass #3, Lane C follow-up): the notch shell reads as one silhouette, keeps red for recording only,
/// and its outer corner radius interpolates instead of snapping. 2.3 U2 (Etan's M4, the 3-wings mock): both wings
/// are one fixed 73.5 pt in every state the mock draws; only controls the mock does not draw (an Ask's hold lock)
/// still widen the left wing.
final class NotchShellCentredTests: XCTestCase {
    private func presentation(history: Bool = false) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
            hasHistoryPanel: history, isHovered: true, isKeyboardFocused: false
        )
    }

    private func shellPath(_ presentation: VoiceBarNotchPresentation) -> Path {
        let geometry = presentation.geometry
        return VoiceBarNotchContinuousShape(
            geometry: geometry,
            compactOuterCornerRadius: VoiceBarNotchContract.material
                .compactOuterCornerRadius(for: presentation.visualState),
            bodyShoulderCornerRadius: VoiceBarNotchContract.material
                .bodyShoulderCornerRadius(for: presentation.visualState)
        ).path(in: CGRect(x: 0, y: 0, width: geometry.totalWidth, height: geometry.totalHeight))
    }

    // MARK: - #3 selected treatment

    func testASelectedNavigationButtonIsNeutralAndOnlyRecordingStateIsRed() {
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: false,
                isSelected: true,
                selectionStyle: .navigation
            ),
            .primaryLabel, "an open History button must not read as recording"
        )
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: false, isSelected: true, selectionStyle: .recordingState
            ),
            .stateAccent
        )
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: true,
                isSelected: false,
                selectionStyle: .navigation
            ),
            .stateAccent
        )

        XCTAssertEqual(
            VoiceBarNotchControlPlate.resolve(
                isDestructive: false, isSelected: true, selectionStyle: .navigation, isHovered: false
            ),
            .neutralSelected
        )
        XCTAssertEqual(
            VoiceBarNotchControlPlate.resolve(
                isDestructive: false, isSelected: true, selectionStyle: .recordingState, isHovered: false
            ),
            .recordingSelected
        )
        XCTAssertEqual(
            VoiceBarNotchControlPlate.resolve(
                isDestructive: true, isSelected: false, selectionStyle: .navigation, isHovered: false
            ),
            .recordingSolid
        )
        XCTAssertEqual(
            VoiceBarNotchControlPlate.resolve(
                isDestructive: false, isSelected: false, selectionStyle: .navigation, isHovered: true
            ),
            .hover
        )
        XCTAssertEqual(
            VoiceBarNotchControlPlate.resolve(
                isDestructive: false, isSelected: false, selectionStyle: .navigation, isHovered: false
            ),
            .none
        )
    }

    // MARK: - fitted wings, one silhouette

    /// 2.3 U2 (M4/M5): the mic and its chevron share the left wing, which is the fixed two-control wing; the 2026-09-30
    /// "the mic's wing hugs the mic" ruling is superseded by the fixed 73 + 73 pt wings.
    func testTheMicAndChevronWingIsTheFixedWingInTheLauncherAndWithHistoryOpen() {
        let micAndChevron = VoiceBarNotchContract.compactContentFitWingWidth(
            contentWidth: 2 * VoiceBarNotchContract.material.compactControlSize
                + VoiceBarNotchContract.material.compactControlSpacing
        )
        XCTAssertEqual(micAndChevron, 73.5)
        XCTAssertEqual(VoiceBarNotchContract.fixedWingWidth, micAndChevron)
        for (name, presentation) in [("hover", presentation()), ("History", presentation(history: true))] {
            let geometry = presentation.geometry
            XCTAssertEqual(geometry.leadingWingWidth, micAndChevron, "\(name): the mic + chevron wing")
            XCTAssertEqual(
                geometry.trailingWingWidth, VoiceBarNotchContract.hoverLauncherTrailingWingWidth,
                "\(name): the History + Settings wing must not change"
            )
            XCTAssertEqual(geometry.trailingWingWidth, 73.5, "\(name)")
        }
    }

    func testTheLeadingWingFitsItsContentInEveryCompactState() {
        let material = VoiceBarNotchContract.material
        let oneControl = VoiceBarNotchContract.compactContentFitWingWidth(contentWidth: material.compactControlSize)
        let twoControls = VoiceBarNotchContract.compactContentFitWingWidth(
            contentWidth: 2 * material.compactControlSize + material.compactControlSpacing
        )
        let expected: [(VoiceBarNotchVisualState, CGFloat)] = [
            (.hoverLauncher, twoControls), // the mic + chevron (2.3 U2)
            (.history, twoControls), // the mic + chevron (2.3 U2)
            (.compactStatus, oneControl), // the status indicator (transcribing, transcript shown)
            (.recording, twoControls), // cancel + stop
        ]
        for (state, width) in expected {
            XCTAssertEqual(VoiceBarNotchContract.geometry(for: state).leadingWingWidth, width, "\(state)")
        }
    }

    /// Where the view draws the leading wing's core-side control, relative to the core's left edge. Mirrors
    /// `VoiceBarNotchView.wingSlot`: the content row sits in the wing, inset 14 pt outside and 13.5 pt core-side.
    /// 2.3 U2: BarView frames the leading row to the core side (`.frame(maxWidth: .infinity, alignment: .trailing)`),
    /// so a row narrower than the fixed wing's lane still hugs the core.
    private func drawnCoreSideLeadingControlMidX(
        _ presentation: VoiceBarNotchPresentation, controlCount: Int
    ) -> CGFloat {
        let material = VoiceBarNotchContract.material
        let slot = material.wingContentLayout(for: .leading, state: presentation.visualState)
        let wing = VoiceBarNotchShapeLayout(geometry: presentation.geometry).leadingWingRect
        let rowWidth = CGFloat(controlCount) * material.compactControlSize
            + CGFloat(controlCount - 1) * material.compactControlSpacing
        let lane = CGRect(
            x: wing.minX + slot.outerInset, y: 0, width: wing.width - slot.outerInset - slot.coreInset, height: 1
        )
        let rowMaxX: CGFloat = switch slot.alignment {
        case .center: rowWidth <= lane.width ? lane.maxX : lane.midX + rowWidth / 2
        case .core: lane.maxX
        case .screenLeading: lane.minX + rowWidth
        }
        return rowMaxX - material.compactControlSize / 2 - presentation.geometry.coreOriginX
    }

    func testTheMicKeepsItsHitTargetAndIsDrawnOnIt() {
        let hover = presentation()
        let geometry = hover.geometry
        let material = VoiceBarNotchContract.material
        let rects = VoiceBarNotchHitRegion(geometry: geometry, configuration: .fallback(for: hover)).rects
        // From the core outward: the chevron 13.5 pt off the core, then the mic one 6 pt gap further out.
        let chevronRect = rects[0], micRect = rects[1]
        XCTAssertEqual(chevronRect.maxX, geometry.coreOriginX - VoiceBarNotchContract.compactCoreContentInset)
        XCTAssertEqual(micRect.maxX, chevronRect.minX - material.compactControlSpacing)
        XCTAssertEqual(micRect.width, material.compactControlSize)
        for (name, presentation) in [("hover", hover), ("History", presentation(history: true))] {
            let targets = VoiceBarNotchHitRegion(
                geometry: presentation.geometry, configuration: .fallback(for: presentation)
            ).rects
            XCTAssertEqual(
                drawnCoreSideLeadingControlMidX(presentation, controlCount: 2),
                targets[0].midX - presentation.geometry.coreOriginX,
                accuracy: 0.001, "\(name): the chevron must be drawn where its hit target is"
            )
            XCTAssertEqual(
                drawnCoreSideLeadingControlMidX(presentation, controlCount: 2)
                    - material.compactControlSize - material.compactControlSpacing,
                targets[1].midX - presentation.geometry.coreOriginX,
                accuracy: 0.001, "\(name): the mic must be drawn where its hit target is"
            )
            // The fixed wing has the same glass on both sides as every state: 14 pt out, 13.5 pt in.
            let wing = VoiceBarNotchShapeLayout(geometry: presentation.geometry).leadingWingRect
            XCTAssertEqual(targets[1].minX - wing.minX, material.compactContentInset, "\(name)")
        }
    }

    /// The core is pinned to the housing, so an x relative to the core is an on-screen x. The control next to the
    /// housing (the mic; cancel or the hold lock while recording; the status indicator) must not move between states.
    func testTheCoreSideLeadingControlKeepsItsScreenXAcrossStates() {
        func resolve(_ input: VoiceBarNotchOperationalInput) -> VoiceBarNotchPresentation {
            VoiceBarPresentation.notchPresentation(from: input)
        }
        let states: [(String, VoiceBarNotchPresentation, Int)] = [
            ("hover", resolve(VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)), 2),
            ("History", presentation(history: true), 2),
            ("recording", resolve(VoiceBarNotchOperationalInput(mode: .recording)), 2),
            ("recording + hold lock",
             resolve(VoiceBarNotchOperationalInput(mode: .recording, showsRecordingHold: true)), 3),
            ("transcribing", resolve(VoiceBarNotchOperationalInput(mode: .transcribing)), 1),
            ("transcript shown",
             resolve(VoiceBarNotchOperationalInput(mode: .idle, confirmationText: "Pasted", statusText: "Pasted")), 1),
        ]
        let expected = -(VoiceBarNotchContract.compactCoreContentInset
            + VoiceBarNotchContract.material.compactControlSize / 2)
        XCTAssertEqual(expected, -23.5)
        for (name, presentation, controlCount) in states {
            XCTAssertEqual(
                drawnCoreSideLeadingControlMidX(presentation, controlCount: controlCount), expected,
                accuracy: 0.001, "\(name): the core-side control moved"
            )
            // 2.3 U2: every state the 3-wings mock draws uses the fixed two-control wing; only a third control (the
            // hold lock) widens it. A shown transcript (not a mock state) keeps its fitted status lane.
            let fit = VoiceBarNotchContract.compactContentFitWingWidth(
                contentWidth: CGFloat(controlCount) * VoiceBarNotchContract.material.compactControlSize
                    + CGFloat(controlCount - 1) * VoiceBarNotchContract.material.compactControlSpacing
            )
            XCTAssertEqual(
                presentation.geometry.leadingWingWidth,
                name == "transcript shown" ? fit : max(VoiceBarNotchContract.fixedWingWidth, fit),
                "\(name): the leading wing is not the fixed wing for its \(controlCount) control(s)"
            )
        }
    }

    func testTheWingsLeaveNoUncoveredPocketBesideTheHousing() {
        let core = VoiceBarNotchHardwareCoreShape(
            lowerCornerRadius: VoiceBarNotchContract.material.hardwareCoreLowerCornerRadius
        )
        for (name, presentation) in [("hover", presentation()), ("History", presentation(history: true))] {
            let geometry = presentation.geometry
            let layout = VoiceBarNotchShapeLayout(geometry: geometry)
            let glass = shellPath(presentation)
            let housing = core.path(in: layout.coreRect)
            for y in stride(from: CGFloat(0.5), to: geometry.topHeight, by: 1) {
                for x in stride(from: layout.leadingWingRect.minX + 16, to: layout.trailingWingRect.maxX - 16,
                                by: 0.5) {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertTrue(
                        glass.contains(point) || housing.contains(point),
                        "\(name): nothing covers (\(x), \(y)) beside the housing"
                    )
                }
            }
            XCTAssertFalse(
                glass.contains(CGPoint(x: layout.coreRect.midX, y: 16)), "\(name): glass must never cover the housing"
            )
        }
    }

    /// 2.3 U2: with both wings at the fixed 73.5 pt, the History panel is flush with the wings on both sides (it was
    /// flush on the right and stepped out past the old 47.5 pt mic wing on the left). The outline still only moves
    /// outward on the way down, so there is no pocket. Lane U4 (History morph B, 420 pt) reshapes this panel next.
    func testTheHistoryPanelIsFlushWithBothFixedWings() {
        let history = presentation(history: true)
        let layout = VoiceBarNotchShapeLayout(geometry: history.geometry)
        let wing = layout.leadingWingRect
        let body = layout.bodyRect
        XCTAssertEqual(body.maxX, layout.trailingWingRect.maxX, "the panel's right edge meets the wing's")
        XCTAssertEqual(body.minX, wing.minX, "the panel's left edge meets the fixed wing's")

        let glass = shellPath(history)
        var subpaths = 0
        glass.forEach { if case .move = $0 { subpaths += 1 } }
        XCTAssertEqual(subpaths, 1, "one continuous shell path")
        XCTAssertEqual(glass.boundingRect.minX, body.minX, accuracy: 0.001)
        XCTAssertEqual(glass.boundingRect.maxX, body.maxX, accuracy: 0.001, "no shoulder sticks out")
        for y in stride(from: CGFloat(1), to: body.minY + 40, by: 1) {
            XCTAssertTrue(glass.contains(CGPoint(x: body.maxX - 0.5, y: y)), "right side at y \(y)")
            XCTAssertTrue(glass.contains(CGPoint(x: body.minX + 0.5, y: y)), "left side at y \(y)")
        }
    }

    /// X15 r1 (#235): the History outline has no concave fillet where the wing meets the panel's top edge (the
    /// teleprompter's 5 pt inverse join). 2.3 U2: with the panel flush under the fixed wing there is no step-out
    /// corner at all, so neither a concave nor a convex curve may appear there.
    func testTheHistoryLeftEdgeHasNoConcaveCurve() {
        let history = presentation(history: true)
        let layout = VoiceBarNotchShapeLayout(geometry: history.geometry)
        var current = CGPoint.zero
        var concave = 0
        var convex = 0
        for element in Self.elements(of: shellPath(history)) {
            switch element {
            case let .move(to: point), let .line(to: point):
                current = point
            case let .quadCurve(to: end, control: control):
                if current.x <= layout.leadingWingRect.minX + 0.01, current.y > 0,
                   end.y <= layout.bodyRect.minY + 15 {
                    let turnA: CGFloat = (control.x - current.x) * (end.y - control.y)
                    let turnB: CGFloat = (control.y - current.y) * (end.x - control.x)
                    let turn = turnA - turnB
                    if turn > 0.01 { concave += 1 }
                    if turn < -0.01 { convex += 1 }
                }
                current = end
            default:
                break
            }
        }
        XCTAssertEqual(concave, 0, "History's left edge must not have a concave shoulder")
        XCTAssertEqual(convex, 0, "a flush panel has no step-out corner")
    }

    /// X15 r1 (#235): the left outline jumped 1.08 pt between two almost identical morph frames, where the body
    /// outline switched from one construction to another. Sampled densely over the whole morph, the outline must
    /// never move more than the geometry itself does between neighbouring frames. Closing replays the same
    /// frames in reverse, so this covers both directions.
    func testTheOutlineMovesContinuouslyThroughEveryMorphFrame() {
        let launcher = presentation()
        let status = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
            isHovered: false, isKeyboardFocused: false
        )
        let teleprompter = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
            isHovered: false, isKeyboardFocused: false
        )
        for (name, from, to) in [
            ("hover → History", launcher, presentation(history: true)),
            ("status → teleprompter", status, teleprompter),
        ] {
            let material = VoiceBarNotchContract.material
            let start = VoiceBarNotchContinuousShape(
                geometry: from.geometry,
                compactOuterCornerRadius: material.compactOuterCornerRadius(for: from.visualState),
                bodyShoulderCornerRadius: material.bodyShoulderCornerRadius(for: from.visualState)
            )
            let travel = VoiceBarNotchContinuousShape(
                geometry: to.geometry,
                compactOuterCornerRadius: material.compactOuterCornerRadius(for: to.visualState),
                bodyShoulderCornerRadius: material.bodyShoulderCornerRadius(for: to.visualState)
            ).animatableData - start.animatableData
            /// The leading outline's x relative to the core (which the morph canvas pins), at three heights:
            /// just under the wing, a point into the body, and a point above the bottom edge. Solved from the
            /// path's own segments: `Path.contains` flattens curves and is off by over a point near a corner.
            func edges(_ progress: Double) -> [CGFloat] {
                var shape = start
                var advance = travel
                advance.scale(by: progress)
                shape.animatableData = start.animatableData + advance
                let geometry = shape.geometry
                let layout = VoiceBarNotchShapeLayout(geometry: geometry)
                let path = shape.path(in: CGRect(x: 0, y: 0, width: geometry.totalWidth, height: geometry.totalHeight))
                return [geometry.topHeight + 0.05, geometry.topHeight + 1, geometry.totalHeight - 1].map { y in
                    Self.leftmostCrossing(of: path, atY: y) - geometry.coreOriginX
                }
            }
            // From the frame where the body is 2 pt tall (its three probes are inside it), finely at first.
            let first = 2 / Double(to.geometry.lowerSurfaceHeight)
            let samples = Array(stride(from: first, to: 0.15, by: 1.0 / 20000))
                + Array(stride(from: 0.15, through: 1, by: 1.0 / 2000))
            var previous = edges(first)
            for progress in samples.dropFirst() {
                let current = edges(progress)
                for (before, after) in zip(previous, current) {
                    XCTAssertLessThan(abs(after - before), 0.2, "\(name): the outline jumps at progress \(progress)")
                }
                previous = current
            }
        }
    }

    private static func elements(of path: Path) -> [Path.Element] {
        var elements: [Path.Element] = []
        path.forEach { elements.append($0) }
        return elements
    }

    /// The smallest x at which the path's outline crosses the horizontal line at `y`.
    private static func leftmostCrossing(of path: Path, atY y: CGFloat) -> CGFloat {
        var leftmost = CGFloat.infinity
        var start = CGPoint.zero
        var current = CGPoint.zero
        func line(to end: CGPoint) {
            if min(current.y, end.y) <= y, y <= max(current.y, end.y), current.y != end.y {
                leftmost = min(leftmost, current.x + (end.x - current.x) * (y - current.y) / (end.y - current.y))
            }
            current = end
        }
        for element in elements(of: path) {
            switch element {
            case let .move(to: point):
                start = point
                current = point
            case let .line(to: point):
                line(to: point)
            case let .quadCurve(to: end, control: control):
                // (1 - t)² y0 + 2t(1 - t) yc + t² y1 = y
                let a = current.y - 2 * control.y + end.y
                let b = 2 * (control.y - current.y)
                let c = current.y - y
                let roots: [CGFloat] = if abs(a) < 1e-12 {
                    abs(b) < 1e-12 ? [] : [-c / b]
                } else if b * b - 4 * a * c >= 0 {
                    [
                        (-b + (b * b - 4 * a * c).squareRoot()) / (2 * a),
                        (-b - (b * b - 4 * a * c).squareRoot()) / (2 * a),
                    ]
                } else {
                    []
                }
                for t in roots where t >= 0 && t <= 1 {
                    leftmost = min(
                        leftmost, (1 - t) * (1 - t) * current.x + 2 * t * (1 - t) * control.x + t * t * end.x
                    )
                }
                current = end
            case .curve:
                XCTFail("the shell outline has no cubic curves")
            case .closeSubpath:
                line(to: start)
            }
        }
        return leftmost
    }

    // MARK: - Lane C: the outer radius interpolates

    func testTheOuterCornerRadiusIsPartOfTheAnimatedData() {
        let geometry = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let from = VoiceBarNotchContinuousShape(geometry: geometry, compactOuterCornerRadius: 15)
        let to = VoiceBarNotchContinuousShape(geometry: geometry, compactOuterCornerRadius: 11)
        var midpoint = from.animatableData
        midpoint += to.animatableData
        midpoint.scale(by: 0.5)
        var shape = from

        shape.animatableData = midpoint

        XCTAssertEqual(shape.compactOuterCornerRadius, 13, accuracy: 0.001)
    }

    func testAPanelThatHasJustStartedToGrowKeepsTheWingsRoundedCorners() {
        // Hover → History, one frame in: the body is 1 pt tall. The old body path drew its bottom corners at
        // min(18, body height / 2) = 0.5 pt, so the 15 pt wing corners snapped square on the first frame.
        // A real first frame: every value has moved 1/360 of its way, so the left step-out is 0.07 pt deep.
        let hover = VoiceBarNotchGeometryAnimatableData(geometry: VoiceBarNotchContract.geometry(for: .hoverLauncher))
        var travel = VoiceBarNotchGeometryAnimatableData(geometry: VoiceBarNotchContract.geometry(for: .history))
        travel -= hover
        travel.scale(by: 1.0 / 360)
        let frameOne = (hover + travel).geometry
        XCTAssertEqual(frameOne.lowerSurfaceHeight, 1, accuracy: 0.001)
        let path = VoiceBarNotchContinuousShape(
            geometry: frameOne, compactOuterCornerRadius: 15, bodyShoulderCornerRadius: 15
        ).path(in: CGRect(x: 0, y: 0, width: frameOne.totalWidth, height: frameOne.totalHeight))
        let layout = VoiceBarNotchShapeLayout(geometry: frameOne)
        let cornerProbe = CGPoint(x: layout.leadingWingRect.minX + 1, y: frameOne.totalHeight - 1)

        XCTAssertFalse(path.contains(cornerProbe), "the bottom-left corner went square on the first frame")
    }
}
