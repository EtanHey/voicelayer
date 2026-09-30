import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-2 (UX pass #3, Lane C follow-up): the notch shell reads as one silhouette, keeps red for recording only,
/// and its outer corner radius interpolates instead of snapping. UX pass #4's equal wings were withdrawn by Etan
/// (2026-09-30): every leading wing fits its own content.
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

    /// Etan, 2026-09-30: "the left wing fit width on where the mic icon was. Now it's two identical-width wings."
    /// His call overrides UX pass #4 (equal wings): the mic's wing is exactly as wide as the mic needs.
    func testTheMicWingHugsTheMicInTheLauncherAndWithHistoryOpen() {
        let micFit = VoiceBarNotchContract.compactContentFitWingWidth(
            contentWidth: VoiceBarNotchContract.material.compactControlSize
        )
        XCTAssertEqual(micFit, 47.5)
        XCTAssertEqual(VoiceBarNotchContract.compactIndicatorLaneWidth, micFit)
        for (name, presentation) in [("hover", presentation()), ("History", presentation(history: true))] {
            let geometry = presentation.geometry
            XCTAssertEqual(geometry.leadingWingWidth, micFit, "\(name): the mic's wing is wider than the mic needs")
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
            (.hoverLauncher, oneControl), // the mic
            (.history, oneControl), // the mic
            (.compactStatus, oneControl), // the status indicator (transcribing, transcript shown)
            (.recording, twoControls), // cancel + stop
        ]
        for (state, width) in expected {
            XCTAssertEqual(VoiceBarNotchContract.geometry(for: state).leadingWingWidth, width, "\(state)")
        }
    }

    /// Where the view draws the leading wing's core-side control, relative to the core's left edge. Mirrors
    /// `VoiceBarNotchView.wingSlot`: the content row sits in the wing, inset 14 pt outside and 13.5 pt core-side.
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
        case .center: lane.midX + rowWidth / 2
        case .core: lane.maxX
        case .screenLeading: lane.minX + rowWidth
        }
        return rowMaxX - material.compactControlSize / 2 - presentation.geometry.coreOriginX
    }

    func testTheMicKeepsItsHitTargetAndIsDrawnOnIt() {
        let hover = presentation()
        let geometry = hover.geometry
        let micRect = VoiceBarNotchHitRegion(geometry: geometry, configuration: .fallback(for: hover)).rects[0]
        // Unchanged since before UXP-2: 13.5 pt off the core, one 20 pt control.
        XCTAssertEqual(micRect.maxX, geometry.coreOriginX - VoiceBarNotchContract.compactCoreContentInset)
        XCTAssertEqual(micRect.width, VoiceBarNotchContract.material.compactControlSize)
        for (name, presentation) in [("hover", hover), ("History", presentation(history: true))] {
            let target = VoiceBarNotchHitRegion(
                geometry: presentation.geometry, configuration: .fallback(for: presentation)
            ).rects[0]
            XCTAssertEqual(
                drawnCoreSideLeadingControlMidX(presentation, controlCount: 1),
                target.midX - presentation.geometry.coreOriginX,
                accuracy: 0.001, "\(name): the mic must be drawn where its hit target is"
            )
            // Fitted, the mic has the same glass on both sides as in the status states: 14 pt out, 13.5 pt in.
            let wing = VoiceBarNotchShapeLayout(geometry: presentation.geometry).leadingWingRect
            XCTAssertEqual(target.minX - wing.minX, VoiceBarNotchContract.material.compactContentInset, "\(name)")
        }
    }

    /// The core is pinned to the housing, so an x relative to the core is an on-screen x. The control next to the
    /// housing (the mic; cancel or the hold lock while recording; the status indicator) must not move between states.
    func testTheCoreSideLeadingControlKeepsItsScreenXAcrossStates() {
        func resolve(_ input: VoiceBarNotchOperationalInput) -> VoiceBarNotchPresentation {
            VoiceBarPresentation.notchPresentation(from: input)
        }
        let states: [(String, VoiceBarNotchPresentation, Int)] = [
            ("hover", resolve(VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)), 1),
            ("History", presentation(history: true), 1),
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
            // And the wing is exactly as wide as its controls need: no dead glass on either side.
            XCTAssertEqual(
                presentation.geometry.leadingWingWidth,
                VoiceBarNotchContract.compactContentFitWingWidth(
                    contentWidth: CGFloat(controlCount) * VoiceBarNotchContract.material.compactControlSize
                        + CGFloat(controlCount - 1) * VoiceBarNotchContract.material.compactControlSpacing
                ),
                "\(name): the leading wing does not fit its \(controlCount) control(s)"
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

    /// The right side is flush (UXP-2). The left steps out from the mic's fitted wing to the panel's unchanged
    /// edge with one convex corner: the outline only ever moves outward on the way down, so there is no pocket.
    func testTheHistoryPanelIsFlushOnTheRightAndStepsOutConvexlyOnTheLeft() {
        let history = presentation(history: true)
        let layout = VoiceBarNotchShapeLayout(geometry: history.geometry)
        let wing = layout.leadingWingRect
        let body = layout.bodyRect
        XCTAssertEqual(body.maxX, layout.trailingWingRect.maxX, "the panel's right edge meets the wing's")
        XCTAssertEqual(wing.minX - body.minX, 26, "the panel steps out past the mic's wing")

        let glass = shellPath(history)
        var subpaths = 0
        glass.forEach { if case .move = $0 { subpaths += 1 } }
        XCTAssertEqual(subpaths, 1, "one continuous shell path")
        XCTAssertEqual(glass.boundingRect.minX, body.minX, accuracy: 0.001)
        XCTAssertEqual(glass.boundingRect.maxX, body.maxX, accuracy: 0.001, "no shoulder sticks out")
        for y in stride(from: CGFloat(1), to: body.minY + 40, by: 1) {
            XCTAssertTrue(glass.contains(CGPoint(x: body.maxX - 0.5, y: y)), "right side at y \(y)")
        }

        /// The left outline: the leftmost covered x at each height.
        func leftEdge(_ y: CGFloat) -> CGFloat {
            var x = body.minX
            while x < wing.maxX, !glass.contains(CGPoint(x: x, y: y)) {
                x += 0.25
            }
            return x
        }
        var previous = leftEdge(0.5)
        XCTAssertEqual(previous, wing.minX, accuracy: 0.25, "the wing fits the mic above the panel")
        for y in stride(from: CGFloat(1.5), to: body.minY + 60, by: 1) {
            let edge = leftEdge(y)
            XCTAssertLessThanOrEqual(edge, previous + 0.25, "the outline turns back inward at y \(y): a pocket")
            previous = edge
        }
        XCTAssertEqual(previous, body.minX, accuracy: 0.25, "the step-out reaches the panel's edge")
        // A rounded, convex outer corner rather than a square ledge.
        let radius = VoiceBarNotchContract.material.bodyShoulderCornerRadius(for: .history)
        XCTAssertEqual(radius, 15)
        XCTAssertFalse(glass.contains(CGPoint(x: body.minX + 1, y: body.minY + 1)), "the step-out corner is square")
        XCTAssertTrue(glass.contains(CGPoint(x: body.minX + radius, y: body.minY + 1)))
        XCTAssertTrue(glass.contains(CGPoint(x: body.minX + 1, y: body.minY + radius)))
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
