@testable import VoiceBarUI
import XCTest

final class SpeechSettingsTests: XCTestCase {
    static func controls(rateSource: String = "settings", rate: String = "+10%") -> [String: Any] {
        func field(_ value: Any, source: String = "default") -> [String: Any] {
            ["source": source, "raw": source == "default" ? NSNull() : value, "effective": value]
        }
        let profile: [String: Any] = ["engine": field("edge"), "voice": field("en-US-JennyNeural"),
            "rate": field(rate, source: rateSource), "last_first_audio_ms": 800]
        return ["profiles": ["short": profile, "long": profile], "short_limit_chars": field(400),
                "clone_daemon": "down", "available_voices": [["engine": "edge", "voice": "en-US-JennyNeural"],
                                                            ["engine": "clone", "voice": "theo-c4"]]]
    }
    func testParsingAndLockRendering() throws {
        let state = try XCTUnwrap(SpeechControlsState(controls: Self.controls(rateSource: "environment")))
        XCTAssertEqual(state.profiles[.short]?.rate.source, .environment)
        XCTAssertEqual(state.profiles[.short]?.rate.raw, .string("+10%"))
        XCTAssertEqual(state.voices(for: "clone"), ["theo-c4"])
        XCTAssertEqual(state.profiles[.short]?.latencyLabel, "First audio: 0.8 s")
        XCTAssertEqual(state.lockReason(for: "short.rate"), "Set by QA_VOICE_TTS_RATE")
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("short.rate", controls: state, pending: [:]))
        XCTAssertFalse(SpeechSettingsView.fieldDisabled("short.engine", controls: state, pending: [:]))
        XCTAssertNil(SpeechControlsState(controls: [:]))
    }
    func testChangeSendsPayloadAndAppliesOnlyMatchingAck() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "recording_state": "idle", "tts_controls": Self.controls()])
        state.setTTSSetting("long.rate", .string("+20%"))
        let command = try XCTUnwrap(commands.last)
        XCTAssertEqual(command["cmd"] as? String, "set_tts_setting")
        XCTAssertEqual(command["key"] as? String, "long.rate")
        XCTAssertEqual(command["value"] as? String, "+20%")
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                           "id": "stale", "tts_controls": Self.controls(rate: "+20%")])
        XCTAssertNotNil(state.speechPending["long.rate"])
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                           "id": command["id"] as Any, "tts_controls": Self.controls(rate: "+20%")])
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertEqual(state.speechControls?.profiles[.long]?.rate.effective, "+20%")
    }
    func testEngineChangeChoosesOnlyATargetEngineVoice() throws {
        let state = try XCTUnwrap(SpeechControlsState(controls: Self.controls()))
        XCTAssertEqual(state.preferredVoice(for: "clone", current: "en-US-JennyNeural"), "theo-c4")
        XCTAssertEqual(state.preferredVoice(for: "edge", current: "theo-c4"), "en-US-JennyNeural")
        XCTAssertNil(state.preferredVoice(for: "missing", current: "theo-c4"))
    }
    func testLockBlocksSendAndDisconnectClearsPending() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.controls(rateSource: "environment")])
        state.setTTSSetting("short.rate", .string("+20%"))
        XCTAssertTrue(commands.isEmpty)
        state.setTTSSetting("short_limit_chars", .number(600))
        XCTAssertEqual(commands.last?["value"] as? Int, 600)
        state.setConnectionStatus(false)
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertNil(state.speechControls)
    }
    func testRejectAndMissingControlsRequestFreshHealth() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        var settled = 0
        state.sendCommand = { commands.append($0) }
        state.onSpeechSettled = { settled += 1 }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.controls()])
        state.setTTSSetting("short.rate", .string("+20%"))
        let id = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "reject", "id": id, "reason": "locked"])
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertTrue(state.speechNotice?.contains("locked") == true)
        XCTAssertEqual(state.speechControls?.profiles[.short]?.rate.effective, "+10%")
        state.setTTSSetting("short.rate", .string("+20%"))
        let second = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept", "id": second])
        XCTAssertEqual(commands.last?["cmd"] as? String, "health")
        XCTAssertGreaterThanOrEqual(settled, 2)
    }
    @MainActor
    func testTimeoutClearsPendingAndRequestsHealth() async throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.speechAckTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.controls()])
        state.setTTSSetting("short.rate", .string("+20%"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertNotNil(state.speechNotice)
        XCTAssertEqual(commands.last?["cmd"] as? String, "health")
    }
    func testPreviewUsesSelectedProfileAndBlocksDuplicateRequest() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "recording_state": "idle", "tts_controls": Self.controls(),
                           "model_status": ["residency": "not_loaded", "configured_effort": "accurate",
                                            "configured_model": ["installed": true]]])
        state.previewTTSProfile(.long)
        let command = try XCTUnwrap(commands.last)
        XCTAssertEqual(command["cmd"] as? String, "preview_tts_profile")
        XCTAssertEqual(command["profile"] as? String, "long")
        state.previewTTSProfile(.short)
        XCTAssertEqual(commands.count, 1)
        state.handleEvent(["type": "ack", "command": "preview_tts_profile", "outcome": "reject",
                           "id": command["id"] as Any, "reason": "busy"])
        XCTAssertTrue(state.speechPending.isEmpty)
    }

}
