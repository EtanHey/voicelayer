@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchScreenGeometryTests: XCTestCase {
    func testAcceptedBuiltInDisplayCalibratesTheAppKitHousingToPhysicalGlass() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )

        XCTAssertEqual(resolved.kind, .hardwareNotch)
        XCTAssertEqual(resolved.housingFrame, CGRect(x: 779.5, y: 1085, width: 168, height: 32))
        XCTAssertEqual(resolved.leadingSeamError, 8.5)
        XCTAssertEqual(resolved.trailingSeamError, 8.5)
        XCTAssertEqual(resolved.visibleCoreOcclusionInset, 8.5)
    }

    func testHardwareCalibrationInsetIsConfigurableWithoutChangingTheFallback() {
        let metrics = VoiceBarNotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
            auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
        )

        XCTAssertEqual(
            VoiceBarNotchScreenGeometry.resolve(
                metrics: metrics,
                hardwareHorizontalCalibrationInset: 0
            ).housingFrame.width,
            185
        )
    }

    func testPanelFramesAnchorToTheFullScreenTopAndKeepTheHousingCenterFixed() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )

        let idleGeometry = resolved.geometry(for: .idle)
        let teleprompterGeometry = resolved.geometry(for: .teleprompter)
        let recordingGeometry = resolved.geometry(for: .recording)
        let idleFrame = resolved.panelFrame(for: idleGeometry)
        let teleprompterFrame = resolved.panelFrame(for: teleprompterGeometry)
        let recordingFrame = resolved.panelFrame(for: recordingGeometry)

        XCTAssertEqual(idleFrame, CGRect(x: 779.5, y: 1085, width: 168, height: 32))
        XCTAssertEqual(teleprompterFrame, CGRect(x: 639.5, y: 889, width: 448, height: 228))
        XCTAssertEqual(idleFrame.midX, resolved.housingFrame.midX)
        XCTAssertEqual(teleprompterFrame.midX, resolved.housingFrame.midX)
        XCTAssertEqual(
            recordingFrame.minX + recordingGeometry.coreOriginX,
            resolved.housingFrame.minX
        )
        XCTAssertEqual(idleFrame.maxY, resolved.screenFrame.maxY)
        XCTAssertEqual(teleprompterFrame.maxY, resolved.screenFrame.maxY)
    }

    func testUnavailableAuxiliaryAreasUseTheDocumentedCenteredFallback() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 100, y: 40, width: 1440, height: 900),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
        )

        XCTAssertEqual(resolved.kind, .flatDisplayFallback)
        XCTAssertEqual(resolved.housingFrame, CGRect(x: 727.5, y: 908, width: 185, height: 32))
        XCTAssertNil(resolved.leadingSeamError)
        XCTAssertNil(resolved.trailingSeamError)
        XCTAssertEqual(resolved.visibleCoreOcclusionInset, 0)
    }

    func testDetectedHousingWidthDrivesThePanelAndRenderedCoreWithoutPerStateBranches() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 760, height: 32),
                auxiliaryTopRightArea: CGRect(x: 961, y: 1085, width: 767, height: 32)
            )
        )
        let geometry = resolved.geometry(for: .recording)
        let frame = resolved.panelFrame(for: geometry)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        let renderedCoreFrame = layout.coreRect.offsetBy(dx: frame.minX, dy: frame.minY)

        XCTAssertEqual(resolved.housingFrame.width, 184)
        XCTAssertEqual(geometry.coreWidth, resolved.housingFrame.width)
        XCTAssertEqual(layout.coreRect.width, resolved.housingFrame.width)
        XCTAssertEqual(renderedCoreFrame.minX, resolved.housingFrame.minX)
        XCTAssertEqual(renderedCoreFrame.maxX, resolved.housingFrame.maxX)
        XCTAssertEqual(frame.width, 52.5 + 184 + 125.5)
    }

    func testCompactFadeStartsAtTheCalibratedPhysicalBezelWithoutASecondKeepOut() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let geometry = resolved.geometry(for: .recording)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        let leadingFade = VoiceBarNotchCoreSeamPlacement.resolve(
            for: .leading,
            coreRect: layout.coreRect,
            visibleCoreOcclusionInset: resolved.visibleCoreOcclusionInset
        )
        let trailingFade = VoiceBarNotchCoreSeamPlacement.resolve(
            for: .trailing,
            coreRect: layout.coreRect,
            visibleCoreOcclusionInset: resolved.visibleCoreOcclusionInset
        )

        XCTAssertEqual(geometry.leadingWingWidth, 52.5)
        XCTAssertEqual(geometry.trailingWingWidth, 125.5)
        XCTAssertEqual(geometry.totalWidth, 346)
        XCTAssertEqual(leadingFade.frame.maxX, layout.coreRect.minX)
        XCTAssertEqual(trailingFade.frame.minX, layout.coreRect.maxX)
        XCTAssertEqual(leadingFade.frame.width, 16)
        XCTAssertEqual(trailingFade.frame.width, 16)
    }
}
