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

    func testClickFormatterAndDispatchAdapterEmitOneAllowlistedLine() throws {
        let secret = "CLICK2 SYNTHETIC PRIVATE SELECTION must_not_be_logged"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fields = try XCTUnwrap(ClickTelemetry.dispatchFields(
            command: ["cmd": "pause", "id": "click2-dispatch", "text": secret, "playback_elapsed_ms": 4200],
            appActive: false, panelKey: true, frontmostBundleID: "com.example.Editor", now: now
        ))
        XCTAssertEqual(fields, [
            "timestamp": ClickTelemetry.timestamp(now), "command": "pause", "command_id": "click2-dispatch",
            "appActive": "false", "panelKey": "true", "frontmost_bundle_id": "com.example.Editor",
        ])
        // A free-form ID or bundle value is refused, and non-click commands are not click telemetry.
        XCTAssertEqual(ClickTelemetry.dispatchFields(
            command: ["cmd": "stop", "id": secret], appActive: true, panelKey: false, frontmostBundleID: secret
        )?["command_id"], "null")
        XCTAssertNil(ClickTelemetry.dispatchFields(
            command: ["cmd": "speak_text", "text": secret], appActive: true, panelKey: true, frontmostBundleID: nil
        ))
        XCTAssertNil(ClickTelemetry.dispatchFields(
            command: ["cmd": "health"], appActive: true, panelKey: true, frontmostBundleID: nil
        ))
        var injected = fields
        injected["text"] = secret
        injected["appKeyWindowTitle"] = secret
        let line = try XCTUnwrap(ClickTelemetry.line(event: "command_dispatch", fields: injected))
        XCTAssertFalse(line.contains(secret))
        XCTAssertFalse(line.contains("\n"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        XCTAssertEqual(Set(record.keys), Set(fields.keys).union(["event"]))
        XCTAssertEqual(record["event"], "command_dispatch")
        XCTAssertNil(ClickTelemetry.line(event: "transcription_final", fields: fields))
    }

    func testClickTelemetryAckOutcomeAndNoopHideAreAllowlisted() throws {
        let secret = "CLICK2_SYNTHETIC_PRIVATE_SELECTION_reason_must_not_be_logged"
        let state = VoiceState()
        state.isConnected = true
        state.controlLayerEventWriter = { _, _ in }
        var records: [(String, [String: String])] = []
        state.diagnosticLogger = { records.append(($0, $1)) }
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.dismissTeleprompter()
        let noop = try XCTUnwrap(records.first { $0.0 == "teleprompter_hide" }?.1)
        XCTAssertEqual(noop["outcome"], "noop")
        state.handleEvent(["type": "state", "state": "speaking", "text": secret, "playback_id": "click2-player", "generation": 2])
        state.togglePlaybackPause()
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "pause", "id": id, "outcome": "reject", "reason": secret])
        state.handleEvent(["type": "ack", "command": "pause", "id": "click2-foreign", "outcome": "accept", "reason": "parked"])
        let bytes = try JSONSerialization.data(withJSONObject: records.map { ["event": $0.0, "fields": $0.1] })
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        let acks = records.filter { $0.0 == "playback_control_ack" }.map(\.1)
        XCTAssertEqual(acks.count, 2)
        XCTAssertEqual(acks[0]["command_id"], id)
        XCTAssertEqual(acks[0]["outcome"], "reject")
        XCTAssertEqual(acks[0]["reason"], "unlisted")
        XCTAssertEqual(acks[0]["owned"], "true")
        XCTAssertEqual(acks[1]["reason"], "parked")
        XCTAssertEqual(acks[1]["owned"], "false")
        XCTAssertNotNil(acks[1]["timestamp"])
    }
}
