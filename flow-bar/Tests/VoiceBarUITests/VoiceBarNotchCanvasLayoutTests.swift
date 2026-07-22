@testable import VoiceBarUI
import XCTest

@MainActor
final class VoiceBarNotchCanvasLayoutTests: XCTestCase {
    func testCanvasKeepsStableMaximumWidthAndStateSizedHeight() {
        let recording = presentation(.recording)
        let teleprompter = presentation(.teleprompter)
        let recordingCanvas = VoiceBarNotchCanvasLayout.resolve(for: recording)
        let teleprompterCanvas = VoiceBarNotchCanvasLayout.resolve(for: teleprompter)

        XCTAssertEqual(recordingCanvas.canvasGeometry.totalWidth, 465)
        XCTAssertEqual(teleprompterCanvas.canvasGeometry.totalWidth, 465)
        XCTAssertEqual(recordingCanvas.canvasGeometry.totalHeight, 32)
        XCTAssertEqual(teleprompterCanvas.canvasGeometry.totalHeight, 228)
        XCTAssertEqual(
            recording.geometry.coreOriginX + recordingCanvas.contentOffsetX,
            recordingCanvas.canvasGeometry.coreOriginX
        )
        XCTAssertEqual(
            teleprompter.geometry.coreOriginX + teleprompterCanvas.contentOffsetX,
            teleprompterCanvas.canvasGeometry.coreOriginX
        )
    }

    func testStableCanvasContainsRecordingGeometryWithTheVADHoldControl() {
        let recording = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            recordingLeadingWingWidth: VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl,
            recordingTrailingWingWidth: VoiceBarNotchContract.waveformWingWidth,
            isHovered: false,
            isKeyboardFocused: false
        )
        let canvas = VoiceBarNotchCanvasLayout.resolve(for: recording)
        let layout = VoiceBarPanelLayout.make(
            presentation: recording,
            canvasGeometry: canvas.canvasGeometry
        )
        let panelBounds = CGRect(origin: .zero, size: layout.panelSize)

        XCTAssertEqual(recording.geometry.totalWidth, 362.5)
        XCTAssertEqual(canvas.canvasGeometry.totalWidth, 465)
        XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.totalWidth, recording.geometry.totalWidth)
        XCTAssertEqual(canvas.canvasGeometry.lowerSurfaceHeight, 0)
        XCTAssertTrue(panelBounds.contains(layout.interactiveHitRect))
    }

    func testStateSizedWindowsKeepTheCoreAndTopEdgeInvariant() {
        let recording = presentation(.recording)
        let teleprompter = presentation(.teleprompter)
        let recordingCanvas = VoiceBarNotchCanvasLayout.resolve(for: recording)
        let teleprompterCanvas = VoiceBarNotchCanvasLayout.resolve(for: teleprompter)
        let recordingLayout = VoiceBarPanelLayout.make(
            presentation: recording,
            canvasGeometry: recordingCanvas.canvasGeometry
        )
        let teleprompterLayout = VoiceBarPanelLayout.make(
            presentation: teleprompter,
            canvasGeometry: teleprompterCanvas.canvasGeometry
        )
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let recordingFrame = recordingLayout.windowFrame(anchoredTo: screen)
        let teleprompterFrame = teleprompterLayout.windowFrame(anchoredTo: screen)
        let recordingCoreMidX = recordingFrame.minX
            + recordingLayout.visibleContentRect.minX
            + recording.geometry.coreMidX
        let teleprompterCoreMidX = teleprompterFrame.minX
            + teleprompterLayout.visibleContentRect.minX
            + teleprompter.geometry.coreMidX

        XCTAssertEqual(recordingLayout.panelSize.height, 49)
        XCTAssertEqual(teleprompterLayout.panelSize.height, 245)
        XCTAssertNotEqual(recordingFrame, teleprompterFrame)
        XCTAssertEqual(recordingFrame.maxY, teleprompterFrame.maxY)
        XCTAssertEqual(recordingCoreMidX, screen.housingFrame.midX)
        XCTAssertEqual(teleprompterCoreMidX, screen.housingFrame.midX)
        XCTAssertFalse(recordingFrame.contains(CGPoint(x: screen.housingFrame.midX, y: 1060)))
        XCTAssertTrue(teleprompterFrame.contains(CGPoint(x: screen.housingFrame.midX, y: 1060)))
        XCTAssertFalse(
            recordingLayout.containsInteractiveContent(
                CGPoint(
                    x: recordingLayout.panelSize.width / 2,
                    y: VoiceBarNotchShadowOutsets.material.bottom + 100
                )
            )
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
