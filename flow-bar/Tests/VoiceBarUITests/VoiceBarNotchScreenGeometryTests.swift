@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchScreenGeometryTests: XCTestCase {
    func testAcceptedBuiltInDisplayMeasuresThePhysicalHousingFromAuxiliaryAreas() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )

        XCTAssertEqual(resolved.kind, .hardwareNotch)
        XCTAssertEqual(resolved.housingFrame, CGRect(x: 771, y: 1085, width: 185, height: 32))
        XCTAssertEqual(resolved.leadingSeamError, 0)
        XCTAssertEqual(resolved.trailingSeamError, 0)
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

        let idleFrame = resolved.panelFrame(
            for: VoiceBarNotchContract.geometry(for: .idle)
        )
        let teleprompterFrame = resolved.panelFrame(
            for: VoiceBarNotchContract.geometry(for: .teleprompter)
        )
        let recordingFrame = resolved.panelFrame(
            for: VoiceBarNotchContract.geometry(for: .recording)
        )

        XCTAssertEqual(idleFrame, CGRect(x: 771, y: 1085, width: 185, height: 32))
        XCTAssertEqual(teleprompterFrame, CGRect(x: 631, y: 889, width: 465, height: 228))
        XCTAssertEqual(idleFrame.midX, resolved.housingFrame.midX)
        XCTAssertEqual(teleprompterFrame.midX, resolved.housingFrame.midX)
        XCTAssertEqual(
            recordingFrame.minX + VoiceBarNotchContract.geometry(for: .recording).coreOriginX,
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
    }

    func testFixedCoreStaysCenteredWhenTheDetectedHousingIsWiderThanTheContractCore() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 760, height: 32),
                auxiliaryTopRightArea: CGRect(x: 961, y: 1085, width: 767, height: 32)
            )
        )
        let geometry = VoiceBarNotchContract.geometry(for: .recording)
        let frame = resolved.panelFrame(for: geometry)
        let fixedCoreMidX = frame.minX + geometry.coreOriginX + geometry.coreWidth / 2

        XCTAssertEqual(resolved.housingFrame.width, 201)
        XCTAssertEqual(fixedCoreMidX, resolved.housingFrame.midX)
    }
}
