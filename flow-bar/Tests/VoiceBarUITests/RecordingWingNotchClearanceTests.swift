import AppKit
@testable import VoiceBarUI
import XCTest

/// Etan, real M4 (build 6d03eae7, 2026-11-08): the recording timer "0:54" sat against, even under, the PHYSICAL notch.
/// The drawn core is AppKit's auxiliary gap pulled in by the 8.5 pt calibration, so the camera glass hides the wing's
/// first `visibleCoreOcclusionInset` points. The timer must clear the real notch edge (auxiliaryTopRightArea.minX) by
/// at least 8 pt, the mic name is never two lines (it leaves the wing for the tooltip and VoiceOver), and the meter
/// stays centred in the wing's VISIBLE part. A flat display (no notch) keeps the plain constants.
@MainActor
final class RecordingWingNotchClearanceTests: XCTestCase {
    /// A 14-inch M4 MacBook Pro: 1512 pt wide, a 202 pt auxiliary gap (the drawn core is 185 pt after calibration).
    private func m4Notch() -> VoiceBarNotchScreenGeometry {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        return VoiceBarNotchScreenGeometry.resolve(metrics: VoiceBarNotchScreenMetrics(
            frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 655, height: 38),
            auxiliaryTopRightArea: CGRect(x: 857, y: 944, width: 655, height: 38)))
    }

    private func recording(_ screen: VoiceBarNotchScreenGeometry) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: .init(
            mode: .recording, statusText: "Recording", coreWidth: screen.housingFrame.width,
            visibleCoreOcclusionInset: screen.visibleCoreOcclusionInset))
    }

    func testTheTimerClearsTheRealNotchEdgeByEightPointsOnTheM4() {
        let screen = m4Notch()
        XCTAssertEqual(screen.kind, .hardwareNotch)
        XCTAssertEqual(screen.visibleCoreOcclusionInset, 8.5, accuracy: 0.001)
        let p = recording(screen)
        let slot = VoiceBarNotchContract.material.wingContentLayout(
            for: .trailing, state: .recording, visibleCoreOcclusionInset: p.visibleCoreOcclusionInset)
        // In wing coordinates from the drawn core edge: the physical notch edge is at the occlusion inset.
        let physicalEdge = screen.visibleCoreOcclusionInset
        XCTAssertEqual(screen.housingFrame.maxX + physicalEdge, 857, accuracy: 0.001, "auxiliaryTopRightArea.minX")
        // X1-23 (C6 L3): long clocks keep minutes and seconds in a narrower face of the same size.
        for time in ["0:00", "0:54", "9:59", "10:00", "59:59"] {
            let text = ceil((time as NSString).size(withAttributes: [.font: VoiceBarClockFace.nsFont(for: time)]).width)
            XCTAssertLessThanOrEqual(text, VoiceBarRecordingWingLabel.width, "\(time) fits its region")
            // The time region is trailing-aligned: its text starts where the region's spare width ends.
            let textMinX = slot.coreInset + (VoiceBarRecordingWingLabel.width - text)
            XCTAssertGreaterThanOrEqual(textMinX - physicalEdge, 8, "\(time) keeps ≥ 8 pt from the real notch")
        }
        let wing = p.geometry.trailingWingWidth
        XCTAssertEqual(wing, p.geometry.leadingWingWidth, "QA 0449: equal space either side of the notch")
        let contentWidth = VoiceBarRecordingWingLabel.width + VoiceBarRecordingWingLabel.recordingTimeGap + WaveformLayout.viewportWidth
        XCTAssertEqual(slot.coreInset + contentWidth + slot.outerInset, wing, accuracy: 0.001,
                       "the row fills the visible wing without an empty outer region")
        XCTAssertLessThanOrEqual(wing, VoiceBarNotchContract.morphCanvasWingCapacity, "inside the morph canvas")
        XCTAssertLessThanOrEqual(wing, 132)
    }

    func testAFlatDisplayKeepsThePlainInsets() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen = VoiceBarNotchScreenGeometry.resolve(metrics: VoiceBarNotchScreenMetrics(
            frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), safeAreaTop: 0,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil))
        XCTAssertEqual(screen.visibleCoreOcclusionInset, 0)
        let p = recording(screen)
        let slot = VoiceBarNotchContract.material.wingContentLayout(for: .trailing, state: .recording)
        XCTAssertEqual(slot.coreInset, VoiceBarNotchContract.fixedWingContentInset)
        XCTAssertEqual(slot.coreInset, slot.outerInset, "equal insets: the meter is centred in the whole wing")
        XCTAssertEqual(p.geometry.trailingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth(visibleCoreOcclusionInset: 0),
                       accuracy: 0.001)
    }

    /// Never two-line text: the wing draws no microphone name; it is the time's tooltip and VoiceOver value.
    func testTheMicrophoneNameIsNeverDrawnInTheWing() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let trailing = try XCTUnwrap(source.components(separatedBy: "private var notchTrailingContent").dropFirst().first)
            .components(separatedBy: "private var notchCompactStatusContent")[0]
        let recording = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
            .components(separatedBy: "case .compactStatus")[0]
        XCTAssertFalse(recording.contains("VoiceBarRecordingMicrophoneRegion"), "no visible microphone name")
        XCTAssertTrue(recording.contains("microphoneName: state.recordingMicrophoneName"), "the name rides on the time")
        let controls = try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("VoiceBarWingControls.swift"),
                                  encoding: .utf8)
        let region = try XCTUnwrap(controls.components(separatedBy: "public struct VoiceBarRecordingTimeRegion").dropFirst().first)
        XCTAssertFalse(region.contains("lineLimit(2)"), "never two-line text")
        XCTAssertTrue(region.contains("PillControlTooltip(text: microphoneName)"))
    }
}
