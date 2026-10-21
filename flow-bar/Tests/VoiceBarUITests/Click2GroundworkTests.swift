@testable import VoiceBarUI
import XCTest

@MainActor
final class Click2GroundworkTests: XCTestCase {
    func testClickTelemetryStateApplyDropAndLocalHideAreAllowlisted() throws {
        let secret = "CLICK2_SYNTHETIC_PRIVATE_SELECTION_must_not_be_logged"
        let state = VoiceState()
        state.isConnected = true
        state.controlLayerEventWriter = { _, _ in }
        var records: [(String, [String: String])] = []
        state.diagnosticLogger = { records.append(($0, $1)) }
        state.sendCommand = { _ in }
        state.handleEvent([
            "type": "state", "state": "speaking", "text": secret,
            "playback_id": "click2-player", "generation": 2, "duration_ms": 10000,
        ])
        state.dismissTeleprompter()
        state.togglePlaybackPause()
        state.handleEvent([
            "type": "playback_state", "state": "paused", "playback_id": "click2-player",
            "generation": 3, "offset_ms": 0,
        ])
        state.handleEvent([
            "type": "playback_state", "state": "paused", "playback_id": "click2-player",
            "generation": 1, "offset_ms": 9000,
        ])
        let bytes = try JSONSerialization.data(withJSONObject: records.map { ["event": $0.0, "fields": $0.1] })
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        for (event, match) in [("playback_state_apply", "match"), ("playback_state_drop", "mismatch")] {
            let details = try XCTUnwrap(records.first { $0.0 == event }?.1)
            XCTAssertEqual(details["generation_match"], match)
            XCTAssertNotNil(details["generation"])
            XCTAssertNotNil(details["timestamp"])
        }
        let hidden = try XCTUnwrap(records.first { $0.0 == "teleprompter_hide" }?.1)
        XCTAssertEqual(hidden["dismissed"], "true")
        XCTAssertNotNil(hidden["timestamp"])
    }

    func testPreparationPauseConfirmationShowsPlayAndPlaySendsResume() {
        let state = VoiceState()
        state.isConnected = true
        state.controlLayerEventWriter = { _, _ in }
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent([
            "type": "state", "state": "speaking", "text": "Preparing speech…",
            "long_read": ["id": "click2-read", "chunk_index": 0, "chunk_count": 1,
                          "chunk_start_ms": 0, "preparing": true, "text": "Synthetic selection",
                          "chunk_word_starts": [0]],
        ])
        state.togglePlaybackPause()
        XCTAssertEqual(sent.last?["cmd"] as? String, "pause")
        state.handleEvent([
            "type": "playback_state", "state": "paused", "playback_id": "click2-player",
            "generation": 2, "offset_ms": 0, "chunk_offset_ms": 0,
        ])
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(VoiceBarPresentation.playbackPauseControl(
            mode: state.mode, isPaused: state.isPlaybackPaused, isReadback: false
        )?.iconName, "play.fill")
        state.togglePlaybackPause()
        XCTAssertEqual(sent.last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent.last?["playback_id"] as? String, "click2-player")
        XCTAssertEqual(sent.last?["generation"] as? Int, 2)
    }
}
