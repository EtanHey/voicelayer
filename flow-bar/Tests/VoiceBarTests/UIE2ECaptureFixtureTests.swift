import Foundation
@testable import VoiceBar
import VoiceBarUI
import XCTest

@MainActor
final class UIE2ECaptureFixtureTests: XCTestCase {
    func testPTTAndVADHaveCaptureOpenTimeAndSyntheticLevelsWithoutCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let model = UIE2EModel(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        for (name, mode, elapsed) in [("recording-ptt", "ptt", 12_000), ("recording-vad", "vad", 12_000),
                                       ("recording-ptt-long", "ptt", 3_661_000)] {
            model.fixture(name)
            XCTAssertEqual(model.voice.recordingMode, mode)
            XCTAssertTrue(model.voice.isRecordingCaptureOpen)
            XCTAssertEqual(model.voice.recordingElapsedMilliseconds(), elapsed)
            model.advanceSyntheticCapture(milliseconds: 50)
            XCTAssertEqual(model.voice.recordingElapsedMilliseconds(), elapsed + 50)
            XCTAssertGreaterThan(model.voice.audioLevel ?? 0, 0)
            XCTAssertEqual(model.voice.recordingMicrophoneName, "Synthetic input (no microphone)")
        }
        XCTAssertFalse(model.commands.contains { ["record", "ptt_start"].contains($0["cmd"] as? String ?? "") })
        model.fixture("idle")
        XCTAssertFalse(model.voice.isRecordingCaptureOpen)
        XCTAssertEqual(model.voice.recordingElapsedMilliseconds(), 0)
    }

    func testInvalidGuestRootExplainsTheRequiredBasename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("x9-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        XCTAssertThrowsError(try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path])) { error in
            XCTAssertTrue(error.localizedDescription.contains("vl-ui-*"), error.localizedDescription)
        }
    }
    func testHostGeometryFeedsRenderedAndHitLayoutsAndFlatGuestIsExplicit() throws {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        let metrics = VoiceBarNotchScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085), safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 780, height: 32),
            auxiliaryTopRightArea: CGRect(x: 948, y: 1085, width: 780, height: 32))
        let geometry = VoiceBarNotchScreenGeometry.resolve(metrics: metrics)
        let layout = UIE2EHost.panelLayout(for: state, screenGeometry: geometry)
        let model = VoiceBarNotchPresentationModel()
        AppDelegate.refreshNotchPresentationModel(model, for: state, coreWidth: geometry.housingFrame.width,
            visibleCoreOcclusionInset: geometry.visibleCoreOcclusionInset)
        XCTAssertEqual(layout.presentation, model.presentation)
        XCTAssertEqual(layout.windowFrame(anchoredTo: geometry).maxY, metrics.frame.maxY)
        let guest = VoiceBarNotchScreenGeometry.resolve(metrics: .init(frame: metrics.frame,
            visibleFrame: metrics.visibleFrame, safeAreaTop: 0, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil))
        XCTAssertEqual(guest.kind, .flatDisplayFallback)
        XCTAssertEqual(guest.visibleCoreOcclusionInset, 0)
    }

}
