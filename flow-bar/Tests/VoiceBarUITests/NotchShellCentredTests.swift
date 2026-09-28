import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-2 (UX pass #3 + #4, Lane C follow-up): the notch shell is centred on the housing, reads as one silhouette,
/// keeps red for recording only, and its outer corner radius interpolates instead of snapping.
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
                .compactOuterCornerRadius(for: presentation.visualState)
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

    // MARK: - #4 centred, one silhouette

    func testTheLauncherWingsAreEqualSoTheShellIsCentredOnTheHousing() {
        for (name, presentation) in [("hover", presentation()), ("History", presentation(history: true))] {
            let geometry = presentation.geometry
            XCTAssertEqual(geometry.leadingWingWidth, geometry.trailingWingWidth, "\(name): unequal wings")
            let layout = VoiceBarNotchShapeLayout(geometry: geometry)
            XCTAssertEqual(
                layout.coreRect.minX - layout.leadingWingRect.minX,
                layout.trailingWingRect.maxX - layout.coreRect.maxX,
                "\(name): the shell is not centred on the housing"
            )
        }
    }

    func testTheMicKeepsItsHitTargetAndSitsAtTheCoreSideOfItsWing() {
        let hover = presentation()
        let geometry = hover.geometry
        let micRect = VoiceBarNotchHitRegion(geometry: geometry, configuration: .fallback(for: hover)).rects[0]
        // Unchanged from before UXP-2: 13.5 pt off the core, one 20 pt control.
        XCTAssertEqual(micRect.maxX, geometry.coreOriginX - VoiceBarNotchContract.compactCoreContentInset)
        XCTAssertEqual(micRect.width, VoiceBarNotchContract.material.compactControlSize)
        for state in [VoiceBarNotchVisualState.hoverLauncher, .history] {
            XCTAssertEqual(
                VoiceBarNotchContract.material.wingContentLayout(for: .leading, state: state).alignment, .core,
                "\(state): the mic must be drawn where its hit target is"
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

    func testTheHistoryPanelMeetsTheWingsWithNoShoulders() {
        let history = presentation(history: true)
        let layout = VoiceBarNotchShapeLayout(geometry: history.geometry)
        XCTAssertEqual(layout.bodyRect.minX, layout.leadingWingRect.minX, "the panel's left edge meets the wing's")
        XCTAssertEqual(layout.bodyRect.maxX, layout.trailingWingRect.maxX, "the panel's right edge meets the wing's")

        let glass = shellPath(history)
        let bounds = glass.boundingRect
        XCTAssertEqual(bounds.minX, layout.leadingWingRect.minX, accuracy: 0.001, "no shoulder sticks out")
        XCTAssertEqual(bounds.maxX, layout.trailingWingRect.maxX, accuracy: 0.001, "no shoulder sticks out")
        // A straight outer side from the wing into the panel: no concave nick at the join.
        for y in stride(from: CGFloat(1), to: layout.bodyRect.minY + 20, by: 1) {
            XCTAssertTrue(glass.contains(CGPoint(x: layout.leadingWingRect.minX + 0.5, y: y)), "left side at y \(y)")
            XCTAssertTrue(glass.contains(CGPoint(x: layout.trailingWingRect.maxX - 0.5, y: y)), "right side at y \(y)")
        }
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
        let hover = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let history = VoiceBarNotchContract.geometry(for: .history)
        let frameOne = VoiceBarNotchGeometry(
            coreWidth: hover.coreWidth, topHeight: hover.topHeight,
            leadingWingWidth: hover.leadingWingWidth, trailingWingWidth: hover.trailingWingWidth,
            bodyLeadingExtent: history.bodyLeadingExtent, bodyTrailingExtent: history.bodyTrailingExtent,
            lowerSurfaceHeight: 1
        )
        let path = VoiceBarNotchContinuousShape(geometry: frameOne, compactOuterCornerRadius: 15)
            .path(in: CGRect(x: 0, y: 0, width: frameOne.totalWidth, height: frameOne.totalHeight))
        let layout = VoiceBarNotchShapeLayout(geometry: frameOne)
        let cornerProbe = CGPoint(x: layout.leadingWingRect.minX + 1, y: frameOne.totalHeight - 1)

        XCTAssertFalse(path.contains(cornerProbe), "the bottom-left corner went square on the first frame")
    }
}
