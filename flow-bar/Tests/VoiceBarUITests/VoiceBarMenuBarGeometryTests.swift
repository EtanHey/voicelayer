@testable import VoiceBarUI
import XCTest

final class VoiceBarMenuBarGeometryTests: XCTestCase {
    func testSafeAreaZeroClassifiesAsFlatDisplay() {
        let profile = VoiceBarMenuBarGeometry.displayProfile(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 23, width: 1512, height: 956),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertEqual(profile.displayClass, .flat)
        XCTAssertNil(profile.notchRect)
    }

    func testAuxiliaryAreasClassifyNotchedDisplayAndMeasureCameraIslandGap() {
        let profile = VoiceBarMenuBarGeometry.displayProfile(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
            auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
        )

        XCTAssertEqual(profile.displayClass, .notched)
        XCTAssertEqual(profile.notchRect?.minX ?? -1, 769, accuracy: 0.001)
        XCTAssertEqual(profile.notchRect?.width ?? -1, 189, accuracy: 0.001)
        XCTAssertEqual(profile.notchRect?.height ?? -1, 32, accuracy: 0.001)
    }

    func testNotchMeasurementUsesSafeAreaHeightInsteadOfVisibleFrameGap() {
        let profile = VoiceBarMenuBarGeometry.displayProfile(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
            auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
        )

        XCTAssertEqual(profile.notchRect?.minY ?? -1, 1085, accuracy: 0.001)
        XCTAssertEqual(profile.notchRect?.maxY ?? -1, 1117, accuracy: 0.001)
    }

    func testRecordingWingLayoutKeepsContentOutsideCameraSpacer() {
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 769, y: 1085, width: 189, height: 32)
        )

        let layout = profile.islandContentLayout(for: .recording, isCollapsed: false)

        XCTAssertEqual(layout.cameraSpacer.width, 189, accuracy: 0.001)
        XCTAssertFalse(layout.leadingWing.intersects(layout.cameraSpacer))
        XCTAssertFalse(layout.trailingWing.intersects(layout.cameraSpacer))
        XCTAssertEqual(layout.cameraSpacer.midX, layout.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(layout.bounds.width, 289, accuracy: 0.001)
        XCTAssertLessThan(layout.bounds.width, 300)
    }

    func testNotchedWidthsStayNarrowerThanRejectedWideR2Candidate() {
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 769, y: 1085, width: 189, height: 32)
        )

        XCTAssertEqual(profile.islandWidth(for: .idle, isCollapsed: false), 189, accuracy: 0.001)
        XCTAssertEqual(profile.islandWidth(for: .recording, isCollapsed: false), 289, accuracy: 0.001)
        XCTAssertLessThan(profile.islandWidth(for: .recording, isCollapsed: false), 300)
        XCTAssertLessThan(profile.islandWidth(for: .speaking, isCollapsed: false), 340)
    }

    func testNotchedAttachedOriginUsesNotchRectForStateIndependentVerticalPlacement() {
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 769, y: 1085, width: 189, height: 32)
        )

        let idleY = VoiceBarMenuBarGeometry.attachedOriginY(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            panelHeight: profile.islandHeight,
            fallbackTopPadding: Theme.topPadding,
            profile: profile
        )
        let recordingY = VoiceBarMenuBarGeometry.attachedOriginY(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            panelHeight: profile.islandHeight,
            fallbackTopPadding: Theme.topPadding,
            profile: profile
        )

        XCTAssertEqual(idleY, 1085, accuracy: 0.001)
        XCTAssertEqual(recordingY, idleY, accuracy: 0.001)
    }

    func testNotchedExpandedPanelGrowsDownFromTopPinnedNotch() {
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 769, y: 1085, width: 189, height: 32)
        )

        let expandedY = VoiceBarMenuBarGeometry.attachedOriginY(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            panelHeight: 304,
            fallbackTopPadding: Theme.topPadding,
            profile: profile
        )

        XCTAssertEqual(expandedY, 813, accuracy: 0.001)
    }

    func testMenuBarScreenSelectionPrefersBuiltInNotchedDisplayOverMouseScreen() {
        let selected = VoiceBarMenuBarGeometry.preferredMenuBarScreenIndex(
            profiles: [
                .flat,
                VoiceBarMenuBarDisplayProfile(
                    displayClass: .notched,
                    notchRect: CGRect(x: 769, y: 1085, width: 189, height: 32)
                ),
            ],
            isBuiltIn: [false, true],
            mouseScreenIndex: 0
        )

        XCTAssertEqual(selected, 1)
    }

    func testNotchShapeRadiiFollowStealListClosedAndOpenConstants() {
        XCTAssertEqual(VoiceBarNotchShape.closed.topCornerRadius, 6)
        XCTAssertEqual(VoiceBarNotchShape.closed.bottomCornerRadius, 14)
        XCTAssertEqual(VoiceBarNotchShape.open.topCornerRadius, 19)
        XCTAssertEqual(VoiceBarNotchShape.open.bottomCornerRadius, 24)
    }

    func testFlatRecordingLayoutHasNoCameraSpacerAndUsesFullPill() {
        let layout = VoiceBarMenuBarDisplayProfile.flat.islandContentLayout(
            for: .recording,
            isCollapsed: false
        )

        XCTAssertEqual(layout.cameraSpacer.width, 0)
        XCTAssertEqual(layout.bounds.width, layout.leadingWing.width + layout.trailingWing.width, accuracy: 0.001)
    }

    func testAttachedOriginCentersOnNotchWhenPresent() {
        let profile = VoiceBarMenuBarDisplayProfile(
            displayClass: .notched,
            notchRect: CGRect(x: 771, y: 1085, width: 185, height: 32)
        )

        let originX = VoiceBarMenuBarGeometry.attachedOriginX(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
            panelWidth: 177,
            horizontalOffset: 0.5,
            profile: profile
        )

        XCTAssertEqual(originX, 775, accuracy: 0.001)
    }
}
