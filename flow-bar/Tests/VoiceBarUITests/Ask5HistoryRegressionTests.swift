import Foundation
@testable import VoiceBarUI
import XCTest

final class Ask5HistoryRegressionTests: XCTestCase {
    func testDetailNeverExceedsItsViewport() {
        for height: CGFloat in [0, 40, 80, 100, 150, 300, 600] {
            XCTAssertLessThanOrEqual(SettingsHistoryLayout.detailHeight(available: height), height)
        }
    }
    func testHistoryOwnsClippedScrollAndStickyActions() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"))
        XCTAssertTrue(source.contains("SettingsHistoryWorkspace {"))
        XCTAssertTrue(source.contains("recordingHistoryActions(displayedEntry)"))
        XCTAssertTrue(source.contains("SettingsHistoryTranscriptDetail("))
    }
    func testPresetMismatchRemainsHonestAndChunkControlsKeepTheirMeaning() throws {
        let health: [String: Any] = ["type": "health", "recording_state": "idle", "model_status": [
            "configured_model": ["name": "large-v3-turbo", "installed": true],
            "residency": "loaded", "active_model": "large-v3-turbo", "configured_effort": "accurate", "active_effort": "balanced"],
            "polish_controls": ["model_polish": ["source": "default", "raw": NSNull(), "effective": "off"],
                                "outro_gate": ["source": "default", "raw": NSNull(), "effective": false],
                                "smart_chunks": ["source": "environment", "raw": "1", "effective": true]]]
        let state = ModelsSettingsState(healthEvent: health)
        let rows = ModelsSettingsView.recognizerDetailRows(for: state)
        XCTAssertEqual(rows.map(\.value), ["large-v3-turbo", "Accurate", "Balanced"])
        XCTAssertEqual(rows.map(\.label), ["Model", "Configured recognition preset", "Active recognition preset"])
        let controls = try XCTUnwrap(state.polishControls)
        let chunk = try XCTUnwrap(ModelsSettingsView.processingRows(for: controls).first { $0.key == .smartChunks })
        XCTAssertTrue(chunk.isOn)
        XCTAssertEqual(chunk.key.rawValue, "smart_chunks")
        XCTAssertEqual(chunk.lockedReason, "Set by VOICELAYER_STT_SMART_CHUNKS")
        // Copy is concise; backend thresholds and stop behavior remain outside this UI projection.
        XCTAssertEqual(chunk.line, "Splits long Whisper recordings at pauses.")
    }

}
