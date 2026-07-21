@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchHitRegionTests: XCTestCase {
    func testLauncherHitsOnlyMountedMicHistoryAndDictionaryControls() {
        let geometry = VoiceBarNotchContract.geometry(for: .hoverLauncher)
        let region = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )

        XCTAssertEqual(region.rects, [
            CGRect(x: 14, y: 6, width: 20, height: 20),
            CGRect(x: 246, y: 6, width: 20, height: 20),
            CGRect(x: 272, y: 6, width: 20, height: 20),
        ])
        XCTAssertTrue(region.contains(CGPoint(x: 24, y: 16)))
        XCTAssertTrue(region.contains(CGPoint(x: 256, y: 16)))
        XCTAssertTrue(region.contains(CGPoint(x: 282, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: geometry.coreMidX, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: 1, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: 35, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: 293, y: 16)))
    }

    func testVADRecordingHitsExactlyHoldCancelAndStopOnLeadingSide() {
        let region = VoiceBarNotchHitRegion(
            geometry: compactGeometry(leadingWingWidth: 99.5, trailingWingWidth: 78),
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 3
            )
        )

        XCTAssertEqual(region.rects, [
            CGRect(x: 66, y: 6, width: 20, height: 20),
            CGRect(x: 40, y: 6, width: 20, height: 20),
            CGRect(x: 14, y: 6, width: 20, height: 20),
        ])
        XCTAssertEqual(region.rects.map(\.midX), [76, 50, 24])
        XCTAssertFalse(region.contains(CGPoint(x: 296, y: 16)), "waveform is not interactive")
        XCTAssertFalse(region.contains(CGPoint(x: 87, y: 16)), "gap next to core passes through")
    }

    func testPTTRecordingHasCancelAndStopWithoutAHoldPlaceholder() {
        let region = VoiceBarNotchHitRegion(
            geometry: compactGeometry(leadingWingWidth: 73.5, trailingWingWidth: 78),
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 2
            )
        )

        XCTAssertEqual(region.rects.map(\.midX), [50, 24])
        XCTAssertFalse(region.contains(CGPoint(x: 76, y: 16)))
    }

    func testTranscribingHitsOnlyCancelAfterTheWaveformSlot() {
        let geometry = compactGeometry(leadingWingWidth: 47.5, trailingWingWidth: 104)
        let region = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: VoiceBarNotchInteractionConfiguration(
                trailingControlCountFromOuter: 1,
                trailingOuterInset: 8
            )
        )

        XCTAssertEqual(region.rects, [
            CGRect(x: geometry.totalWidth - 28, y: 6, width: 20, height: 20),
        ])
        XCTAssertTrue(region.contains(CGPoint(x: geometry.coreOriginX + geometry.coreWidth + 86, y: 16)))
        XCTAssertFalse(region.contains(CGPoint(x: geometry.coreOriginX + geometry.coreWidth + 47, y: 16)))
    }

    func testTeleprompterHitsOnlyMountedCenteredBottomControls() {
        let geometry = VoiceBarNotchContract.geometry(for: .teleprompter)
        let region = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: VoiceBarNotchInteractionConfiguration(
                lowerControlCount: 4
            )
        )

        XCTAssertEqual(region.rects, [
            CGRect(x: 177.5, y: 14, width: 20, height: 20),
            CGRect(x: 207.5, y: 14, width: 20, height: 20),
            CGRect(x: 237.5, y: 14, width: 20, height: 20),
            CGRect(x: 267.5, y: 14, width: 20, height: 20),
        ])
        XCTAssertTrue(region.contains(CGPoint(x: 187.5, y: 24)))
        XCTAssertTrue(region.contains(CGPoint(x: 277.5, y: 24)))
        XCTAssertFalse(region.contains(CGPoint(x: 232.5, y: 120)), "teleprompter body passes through")
        XCTAssertFalse(region.contains(CGPoint(x: 108, y: 212)), "former dictionary lane passes through")
        XCTAssertFalse(region.contains(CGPoint(x: 176.5, y: 24)), "one point outside the first control passes through")
    }

    func testSuccessiveConfigurationsDropEveryStaleControlRectangle() {
        let geometry = compactGeometry(leadingWingWidth: 99.5, trailingWingWidth: 104)
        let recording = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
        )
        let transcribing = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: VoiceBarNotchInteractionConfiguration(
                trailingControlCountFromOuter: 1,
                trailingOuterInset: 8
            )
        )
        let idle = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: .none
        )

        let oldStopCenter = CGPoint(x: 24, y: 16)
        XCTAssertTrue(recording.contains(oldStopCenter))
        XCTAssertFalse(transcribing.contains(oldStopCenter))
        XCTAssertFalse(idle.contains(oldStopCenter))
        XCTAssertTrue(idle.rects.isEmpty)
    }

    func testVisibleSurfaceRemainsSeparateFromInteractiveControls() {
        let presentation = presentation(.teleprompter)
        let visibleRegion = VoiceBarNotchVisibleRegion(presentation: presentation)

        XCTAssertTrue(visibleRegion.contains(CGPoint(x: 232.5, y: 120)))
        XCTAssertFalse(visibleRegion.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(visibleRegion.contains(CGPoint(x: 10, y: 212)))
    }

    private func compactGeometry(
        leadingWingWidth: CGFloat,
        trailingWingWidth: CGFloat
    ) -> VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: VoiceBarNotchContract.coreWidth,
            topHeight: VoiceBarNotchContract.topHeight,
            leadingWingWidth: leadingWingWidth,
            trailingWingWidth: trailingWingWidth,
            bodyLeadingExtent: 0,
            bodyTrailingExtent: 0,
            lowerSurfaceHeight: 0
        )
    }

    private func presentation(_ state: VoiceBarNotchVisualState) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: state == .teleprompter,
            isRecording: state == .recording,
            hasCompactStatus: state == .compactStatus,
            isHovered: state == .hoverLauncher,
            isKeyboardFocused: false
        )
    }
}
