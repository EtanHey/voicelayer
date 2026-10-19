import AppKit
@testable import VoiceBarUI
import XCTest

final class SpeechSettingsTests: XCTestCase {
    func testNormalCaptionUsesZeroTickRatherThanTrackMidpoint() {
        XCTAssertEqual(SpeechSettingsView.normalRateFraction, 0.375, accuracy: 0.0001)
    }

    /// SETUI1 (Etan, 2026-10-19: "speech rate is fine, though uncentered"): the native knob's centre travels
    /// half a knob in from each end, so the caption follows the knob, not the raw track width.
    func testRateCaptionSitsUnderTheKnobCentre() {
        XCTAssertEqual(SpeechSettingsView.rateCaptionX(fraction: 0.375, width: 300, knobWidth: 20), 115, accuracy: 0.001)
        XCTAssertEqual(SpeechSettingsView.rateCaptionX(fraction: 0, width: 300, knobWidth: 20), 10, accuracy: 0.001)
        XCTAssertEqual(SpeechSettingsView.rateCaptionX(fraction: 1, width: 300, knobWidth: 20), 290, accuracy: 0.001)
        XCTAssertEqual(SpeechSettingsView.rateCaptionX(fraction: 0.375, width: 0, knobWidth: 20), 0, accuracy: 0.001)
    }

    func testRateCaptionMatchesAppKitsOwnKnobAtZero() {
        let slider = NSSlider(value: 0, minValue: SpeechSettingsView.rateRange.lowerBound,
                              maxValue: SpeechSettingsView.rateRange.upperBound, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        let cell = slider.cell as! NSSliderCell
        XCTAssertEqual(
            SpeechSettingsView.rateCaptionX(fraction: SpeechSettingsView.normalRateFraction, width: 300,
                                            knobWidth: SpeechSettingsView.sliderKnobWidth),
            cell.knobRect(flipped: false).midX, accuracy: 0.5
        )
    }

    static func controls(rateSource: String = "settings", rate: String = "+10%") -> [String: Any] {
        func field(_ value: Any, source: String = "default") -> [String: Any] {
            ["source": source, "raw": source == "default" ? NSNull() : value, "effective": value]
        }
        let profile: [String: Any] = ["engine": field("edge"), "voice": field("en-US-JennyNeural"),
            "rate": field(rate, source: rateSource), "last_first_audio_ms": 800,
            "last_first_audio": ["engine": "edge-tts", "origin": "speak", "fallback": false]]
        return ["profiles": ["short": profile, "long": profile], "short_limit_chars": field(400),
                "clone_daemon": "down", "available_voices": [["engine": "edge", "voice": "en-US-JennyNeural"],
                                                            ["engine": "clone", "voice": "theo-c4s"]]]
    }
    func testParsingAndLockRendering() throws {
        let state = try XCTUnwrap(SpeechControlsState(controls: Self.controls(rateSource: "environment")))
        XCTAssertEqual(state.profiles[.short]?.rate.source, .environment)
        XCTAssertEqual(state.profiles[.short]?.rate.raw, .string("+10%"))
        XCTAssertEqual(state.voices(for: "clone"), ["theo-c4s"])
        XCTAssertEqual(state.profiles[.short]?.latencyLabel, "Last speech: first sound after 0.8 s · Fast voice")
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
        XCTAssertEqual(state.preferredVoice(for: "clone", current: "en-US-JennyNeural"), "theo-c4s")
        XCTAssertEqual(state.preferredVoice(for: "edge", current: "theo-c4s"), "en-US-JennyNeural")
        XCTAssertNil(state.preferredVoice(for: "missing", current: "theo-c4s"))
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

    func testEngineEnvironmentLockRendersAndDisablesEngine() throws {
        var raw = Self.controls()
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["short"]?["engine"] = ["source": "environment", "raw": "edge", "effective": "edge"]
        raw["profiles"] = profiles
        let controls = try XCTUnwrap(SpeechControlsState(controls: raw))
        XCTAssertEqual(controls.lockReason(for: "short.engine"), "Set by QA_VOICE_TTS_VOICE")
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("short.engine", controls: controls, pending: [:]))
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": raw])
        state.setTTSProfile(.short, engine: "clone", voice: "theo-c4s")
        XCTAssertTrue(commands.isEmpty)
    }

    func testAtomicEngineChangeSendsOneCommandAndAckSettlesBothFields() throws {
        for kind in SpeechProfile.allCases {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.setConnectionStatus(true)
            state.handleEvent(["type": "health", "tts_controls": Self.controls()])
            state.setTTSProfile(kind, engine: "clone", voice: "theo-c4s")
            XCTAssertEqual(commands.count, 1)
            let command = try XCTUnwrap(commands.first)
            XCTAssertEqual(command["cmd"] as? String, "set_tts_setting")
            XCTAssertEqual(command["profile"] as? String, kind.rawValue)
            XCTAssertEqual(command["engine"] as? String, "clone")
            XCTAssertEqual(command["voice"] as? String, "theo-c4s")
            XCTAssertNil(command["key"])
            XCTAssertNil(command["rate"], "engine switching must not overwrite a rate")
            XCTAssertEqual(state.speechPending["\(kind.rawValue).engine"], .string("clone"))
            XCTAssertEqual(state.speechPending["\(kind.rawValue).voice"], .string("theo-c4s"))
            var updated = Self.controls()
            var profiles = updated["profiles"] as! [String: [String: Any]]
            profiles[kind.rawValue]?["engine"] = ["source": "settings", "raw": "clone", "effective": "clone"]
            profiles[kind.rawValue]?["voice"] = ["source": "settings", "raw": "theo-c4s", "effective": "theo-c4s"]
            updated["profiles"] = profiles
            state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                               "id": command["id"] as Any, "tts_controls": updated])
            XCTAssertTrue(state.speechPending.isEmpty)
            XCTAssertEqual(state.speechControls?.profiles[kind]?.engine.effective, "clone")
            XCTAssertEqual(state.speechControls?.profiles[kind]?.voice.effective, "theo-c4s")
        }
    }
    func testAtomicChangeRejectsInvalidPairAndLockedVoice() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        var raw = Self.controls()
        state.handleEvent(["type": "health", "tts_controls": raw])
        state.setTTSProfile(.short, engine: "clone", voice: "en-US-JennyNeural")
        XCTAssertTrue(commands.isEmpty)
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["short"]?["voice"] = ["source": "environment", "raw": "en-US-JennyNeural", "effective": "en-US-JennyNeural"]
        raw["profiles"] = profiles
        state.handleEvent(["type": "health", "tts_controls": raw])
        state.setTTSProfile(.short, engine: "clone", voice: "theo-c4s")
        XCTAssertTrue(commands.isEmpty)
    }
    @MainActor
    func testAtomicTimeoutClearsBothPendingFields() async throws {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.speechAckTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.controls()])
        state.setTTSProfile(.short, engine: "clone", voice: "theo-c4s")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertNotNil(state.speechNotice)
    }

    func testAtomicRejectClearsBothFieldsAndKeepsDaemonValues() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.controls()])
        state.setTTSProfile(.long, engine: "clone", voice: "theo-c4s")
        state.setTTSProfile(.long, engine: "edge", voice: "en-US-JennyNeural")
        state.setTTSSetting("long.voice", .string("en-US-JennyNeural"))
        XCTAssertEqual(commands.count, 1, "neither half may race the atomic request")
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "reject",
                           "id": commands[0]["id"] as Any, "reason": "invalid pair"])
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertEqual(state.speechControls?.profiles[.long]?.engine.effective, "edge")
        XCTAssertEqual(state.speechControls?.profiles[.long]?.voice.effective, "en-US-JennyNeural")
        XCTAssertTrue(state.speechNotice?.contains("invalid pair") == true)
    }

    func testGroupedVoiceListUsesAtomicCallbackAndKeepsUnlistedSelectionOutOfChoices() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: Self.controls()))
        let display = try XCTUnwrap(SpeechSettingsView.displayProfile(.short, controls: controls,
            pending: ["short.engine": .string("clone"), "short.voice": .string("huberman")]))
        XCTAssertFalse(display.voices.contains("huberman"))
        XCTAssertEqual(SpeechSettingsView.voiceLabel("theo-c4s"), "Theo")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SpeechSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Picker(\"Engine\""))
        XCTAssertTrue(source.contains("Section(\"Fast\""))
        XCTAssertTrue(source.contains("Section(\"Cloned\""))
        XCTAssertTrue(source.contains("onSelectEngine?(kind, selected.engine, selected.voice)"))
        XCTAssertTrue(source.contains("fast voice (fallback)"), "clone-down status must label fallback before a preview")
    }

    func testGroupedSelectionLocksBothFieldsAndFiltersLegacyCatalog() throws {
        var raw = Self.controls()
        raw["available_voices"] = [["engine": "edge", "voice": "custom"],
            ["engine": "clone", "voice": "theo-c4s"], ["engine": "clone", "voice": "theo-c4"],
            ["engine": "clone", "voice": "huberman"], ["engine": "clone", "voice": "ben-c1"]]
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["short"]?["engine"] = ["source": "environment", "raw": "clone", "effective": "clone"]
        raw["profiles"] = profiles
        let controls = try XCTUnwrap(SpeechControlsState(controls: raw))
        XCTAssertEqual(controls.voices(for: "edge"), ["custom"])
        XCTAssertEqual(controls.voices(for: "clone"), ["theo-c4s", "ben-c1"])
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("short.voice", controls: controls, pending: [:]))
        XCTAssertTrue(SpeechSettingsView.lockFooter(.short, controls: controls)?.contains("QA_VOICE_TTS_VOICE") == true)
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("long.voice", controls: controls, pending: ["long.engine": .string("clone")]))
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("long.voice", controls: controls, pending: [:], callbackAvailable: false))
    }

    func testReadyBenSelectionAndFastFallbackAttribution() throws {
        var raw = Self.controls()
        raw["available_voices"] = [["engine": "edge", "voice": "en-US-JennyNeural"],
                                   ["engine": "clone", "voice": "ben-c1"]]
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": raw])
        state.setTTSProfile(.short, engine: "clone", voice: "ben-c1")
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["engine"] as? String, "clone")
        XCTAssertEqual(commands.first?["voice"] as? String, "ben-c1")
        XCTAssertEqual(SpeechSettingsView.voiceLabel("ben-c1"), "Ben")
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["short"]?["engine"] = ["source": "settings", "raw": "clone", "effective": "clone"]
        profiles["short"]?["voice"] = ["source": "settings", "raw": "ben-c1", "effective": "ben-c1"]
        profiles["short"]?["last_first_audio"] = ["engine": "edge-tts", "origin": "preview", "fallback": true]
        raw["profiles"] = profiles
        let controls = try XCTUnwrap(SpeechControlsState(controls: raw))
        let display = try XCTUnwrap(SpeechSettingsView.displayProfile(.short, controls: controls, pending: [:]))
        XCTAssertTrue(display.cloneWarning)
        XCTAssertTrue(controls.profiles[.short]?.latencyLabel.contains("Fast voice (fallback)") == true)
    }
    func testSpeechCopyUsesTheShownCommandAndFullVisibleError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SpeechSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(Self.daemonCommand)"), "The copied command must also be displayed verbatim")
        XCTAssertTrue(source.contains("SettingsCopyButton(text: Self.daemonCommand, label: \"daemon command\")"))
        let noticeStart = try XCTUnwrap(source.range(of: "if let notice, pending[\"preview\"] == nil"))
        let footer = source[noticeStart.lowerBound...]
        XCTAssertTrue(footer.contains("Text(notice)"))
        XCTAssertTrue(footer.contains("SettingsCopyButton(text: notice, label: \"speech error\")"),
                      "Copy must receive the same full error under the same visibility gate")
        XCTAssertFalse(source.contains("Process("), "Showing or copying the command must never execute it")
    }

}
