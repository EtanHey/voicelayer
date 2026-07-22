@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchScreenGeometryTests: XCTestCase {
    func testAcceptedBuiltInDisplayCalibratesTheAppKitHousingToPhysicalGlass() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
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
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
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
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
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
                visibleFrame: CGRect(x: 100, y: 40, width: 1440, height: 876),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
        )

        XCTAssertEqual(resolved.kind, .flatDisplayFallback)
        XCTAssertEqual(resolved.housingFrame, CGRect(x: 727.5, y: 916, width: 185, height: 24))
        XCTAssertNil(resolved.leadingSeamError)
        XCTAssertNil(resolved.trailingSeamError)
        XCTAssertEqual(resolved.visibleCoreOcclusionInset, 0)
        XCTAssertEqual(resolved.virtualNotchIdleCoreHeight, 24)
        XCTAssertEqual(resolved.geometry(for: .idle).topHeight, 24)
        XCTAssertEqual(resolved.geometry(for: .recording).topHeight, 24)
    }

    func testAuxiliaryAreasWithoutASafeAreaInsetDoNotMasqueradeAsHardwareNotch() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 1920, y: -180, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1920, y: -180, width: 2560, height: 1416),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: CGRect(x: 1920, y: 1228, width: 1180, height: 32),
                auxiliaryTopRightArea: CGRect(x: 3300, y: 1228, width: 1180, height: 32)
            )
        )

        XCTAssertEqual(resolved.kind, .flatDisplayFallback)
        XCTAssertEqual(resolved.housingFrame, CGRect(x: 3107.5, y: 1236, width: 185, height: 24))
        XCTAssertEqual(resolved.virtualNotchIdleCoreHeight, 24)
    }

    func testAutoHiddenMenuBarRetainsAThirtyPointInvisibleHoverBand() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            )
        )

        XCTAssertEqual(resolved.housingFrame, CGRect(x: 867.5, y: 1050, width: 185, height: 30))
        XCTAssertEqual(resolved.virtualNotchIdleCoreHeight, 30)
        XCTAssertEqual(resolved.geometry(for: .recording).topHeight, 30)
    }

    func testIdlePaintsNoSoftwareCoreAcrossVisibleHiddenAndHardwareMenuBars() {
        let cases = [
            VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            ),
            VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                safeAreaTop: 0,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            ),
            VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            ),
        ]

        for metrics in cases {
            let screen = VoiceBarNotchScreenGeometry.resolve(metrics: metrics)
            let presentation = VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false,
                coreWidth: screen.housingFrame.width,
                virtualNotchIdleCoreHeight: screen.virtualNotchIdleCoreHeight
            )

            XCTAssertEqual(
                VoiceBarNotchViewDescriptor.resolve(presentation: presentation).fixedCoreCount,
                0,
                "kind=\(screen.kind) visibleFrame=\(metrics.visibleFrame)"
            )
        }
    }

    func testDetectedHousingWidthDrivesThePanelAndRenderedCoreWithoutPerStateBranches() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
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
        XCTAssertEqual(frame.width, 73.5 + 184 + 78)
    }

    func testCompactGlassMeetsTheCalibratedPhysicalBezelWithoutASecondKeepOut() {
        let resolved = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let geometry = resolved.geometry(for: .recording)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        let path = VoiceBarNotchContinuousShape(geometry: geometry).path(
            in: CGRect(origin: .zero, size: layout.totalSize)
        )

        XCTAssertEqual(geometry.leadingWingWidth, 73.5)
        XCTAssertEqual(geometry.trailingWingWidth, 78)
        XCTAssertEqual(geometry.totalWidth, 319.5)
        XCTAssertTrue(path.contains(CGPoint(x: layout.coreRect.minX - 0.5, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: layout.coreRect.maxX + 0.5, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: layout.coreRect.midX, y: 16)))
    }
}
