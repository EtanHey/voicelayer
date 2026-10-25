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

    static func thresholdControls(_ value: Int = 400, source: String = "settings") -> [String: Any] {
        var raw = controls()
        let field: [String: Any] = ["source": source, "raw": source == "default" ? NSNull() : value,
                                    "effective": value]
        raw["short_limit_chars"] = field
        return raw
    }

    func testThresholdTypingDoesNotWriteAndExplicitApplySendsOnePendingCommand() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls()])
        var draft = SpeechThresholdDraft()
        for text in ["2", "20", "200", "2000", "20000"] { draft.edit(text) }
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(draft.displayedText(state.speechControls?.shortLimit), "20000")
        XCTAssertEqual(SpeechThresholdDraft.confirmedLabel(state.speechControls?.shortLimit),
                       "Last reported cutoff: 400 characters · Saved in settings at that report")
        for _ in 0..<2 {
            draft.apply(controls: state.speechControls, connected: true, busy: false,
                        pending: state.speechPending, onChange: state.setTTSSetting)
        }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "set_tts_setting")
        XCTAssertEqual(commands.first?["key"] as? String, "short_limit_chars")
        XCTAssertEqual(commands.first?["value"] as? Int, 20000)
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 400)
        XCTAssertTrue(SpeechThresholdDraft.blockedReason(controls: state.speechControls, connected: true,
            busy: true, pending: state.speechPending, callbackAvailable: true)?.contains("Applying 20000") == true)
        let id = try XCTUnwrap(commands.first?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "reject",
                           "id": id, "reason": "write failed"])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(draft.text, "20000")
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 400)
        XCTAssertTrue(state.speechNotice?.contains("write failed") == true)
        draft.revert()
        XCTAssertEqual(draft.displayedText(state.speechControls?.shortLimit), "400")
        XCTAssertEqual(commands.count, 1, "Revert must never send a command")
    }

    func testThresholdAcceptAndExternalControlsPreserveActiveEdits() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls()])
        var draft = SpeechThresholdDraft()
        draft.edit("20000")
        draft.apply(controls: state.speechControls, connected: true, busy: false,
                    pending: [:], onChange: state.setTTSSetting)
        let id = try XCTUnwrap(commands.first?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                           "id": "stale", "tts_controls": Self.thresholdControls(600)])
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 400)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                           "id": id, "tts_controls": Self.thresholdControls(20000)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertNil(draft.text)
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertEqual(draft.displayedText(state.speechControls?.shortLimit), "20000")
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(600)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(draft.displayedText(state.speechControls?.shortLimit), "600")
        draft.edit("900")
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(700)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(draft.text, "900", "External confirmation must not erase a different local edit")
        draft.revert()
        XCTAssertEqual(draft.displayedText(state.speechControls?.shortLimit), "700")
        XCTAssertEqual(commands.count, 1)
    }

    private func assertLastReportedThreshold(_ state: VoiceState, draft: SpeechThresholdDraft, cutoff: Int,
                                             commandCount: () -> Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SpeechThresholdDraft.confirmedLabel(state.speechControls?.shortLimit),
                       "Last reported cutoff: \(cutoff) characters · Saved in settings at that report", file: file, line: line)
        XCTAssertEqual(SpeechThresholdDraft.reportStatus,
                       "Profile descriptions and Revert use the last reported cutoff; current settings may differ.", file: file, line: line)
        XCTAssertEqual(SpeechThresholdDraft.captionContext,
                       "Based on the last reported cutoff.", file: file, line: line)
        XCTAssertEqual(SpeechThresholdDraft.revertHelp,
                       "Restore the last reported cutoff locally without changing VoiceLayer.", file: file, line: line)
        XCTAssertNil(SpeechThresholdDraft.blockedReason(controls: state.speechControls, connected: true,
            busy: false, pending: state.speechPending, callbackAvailable: true), file: file, line: line)
        XCTAssertEqual(draft.canApply(controls: state.speechControls, connected: true, busy: false,
            pending: state.speechPending, callbackAvailable: true), cutoff == 400, file: file, line: line)
        let sentBeforeRevert = commandCount()
        var reverted = draft
        reverted.revert()
        XCTAssertEqual(reverted.displayedText(state.speechControls?.shortLimit), String(cutoff), file: file, line: line)
        XCTAssertEqual(commandCount(), sentBeforeRevert, file: file, line: line)
    }

    func testThresholdAcceptWithoutControlsWaitsForAuthoritativeHealth() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls()])
        var draft = SpeechThresholdDraft()
        draft.edit("20000")
        draft.apply(controls: state.speechControls, connected: true, busy: false,
                    pending: [:], onChange: state.setTTSSetting)
        let id = try XCTUnwrap(commands.first?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept", "id": id])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(commands.last?["cmd"] as? String, "health")
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 400)
        XCTAssertEqual(draft.text, "20000")
        XCTAssertNil(state.speechNotice, "Missing accept metadata has no notice-based freshness signal")
        XCTAssertTrue(state.speechPending.isEmpty)
        assertLastReportedThreshold(state, draft: draft, cutoff: 400, commandCount: { commands.count })
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(400)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(draft.text, "20000", "A fresh equal-value report must not erase the local draft")
        assertLastReportedThreshold(state, draft: draft, cutoff: 400, commandCount: { commands.count })
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(20000)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertNil(draft.text)
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 20000)
        assertLastReportedThreshold(state, draft: draft, cutoff: 20000, commandCount: { commands.count })
    }

    @MainActor
    func testThresholdTimeoutLateAckAndHealthNeverPromotePendingToApplied() async throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.speechAckTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls()])
        var draft = SpeechThresholdDraft()
        draft.edit("20000")
        draft.apply(controls: state.speechControls, connected: true, busy: false,
                    pending: [:], onChange: state.setTTSSetting)
        let id = try XCTUnwrap(commands.first?["id"] as? String)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.speechPending.isEmpty)
        XCTAssertTrue(state.speechNotice?.contains("Couldn't confirm") == true)
        XCTAssertEqual(commands.last?["cmd"] as? String, "health")
        state.handleEvent(["type": "ack", "command": "set_tts_setting", "outcome": "accept",
                           "id": id, "tts_controls": Self.thresholdControls(20000)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 400)
        XCTAssertEqual(draft.text, "20000")
        XCTAssertTrue(state.speechPending.isEmpty)
        assertLastReportedThreshold(state, draft: draft, cutoff: 400, commandCount: { commands.count })
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(400)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertEqual(draft.text, "20000", "A fresh equal-value report must not erase the local draft")
        assertLastReportedThreshold(state, draft: draft, cutoff: 400, commandCount: { commands.count })
        state.handleEvent(["type": "health", "tts_controls": Self.thresholdControls(20000)])
        draft.reconcile(state.speechControls?.shortLimit)
        XCTAssertNil(draft.text)
        XCTAssertEqual(state.speechControls?.shortLimit.effective, 20000)
        assertLastReportedThreshold(state, draft: draft, cutoff: 20000, commandCount: { commands.count })
    }

    func testThresholdInvalidAndUnchangedDraftsRefuseApplyWithoutClamping() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: Self.thresholdControls()))
        var draft = SpeechThresholdDraft()
        var sent: [SpeechValue] = []
        for text in ["", "no", "0", "-1", "2.5", "9007199254740992", "9223372036854775808", "400"] {
            draft.edit(text)
            draft.apply(controls: controls, connected: true, busy: false, pending: [:],
                        onChange: { _, value in sent.append(value) })
            draft.reconcile(nil)
            XCTAssertEqual(draft.text, text, "Missing controls must preserve even invalid local text")
            XCTAssertEqual(draft.validationMessage == nil, text == "400")
        }
        XCTAssertTrue(sent.isEmpty)
        draft.edit("9007199254740991")
        draft.apply(controls: controls, connected: true, busy: false, pending: [:],
                    onChange: { _, value in sent.append(value) })
        XCTAssertEqual(sent, [.number(9_007_199_254_740_991)])
    }

    func testThresholdGatesAndEnvironmentMetadataDoNotInventSavedTruth() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: Self.thresholdControls()))
        var raw = Self.thresholdControls(600, source: "environment")
        raw["short_limit_chars"] = ["source": "environment", "raw": 400, "effective": 600]
        let locked = try XCTUnwrap(SpeechControlsState(controls: raw))
        var draft = SpeechThresholdDraft()
        draft.edit("20000")
        var sent = 0
        let gates: [(SpeechControlsState?, Bool, Bool, [String: SpeechValue])] = [
            (controls, false, false, [:]), (nil, true, false, [:]), (controls, true, true, [:]),
            (controls, true, false, ["short_limit_chars": .number(20000)]),
            (controls, true, false, ["preview": .string("long")]), (locked, true, false, [:])]
        for (controls, connected, busy, pending) in gates {
            draft.apply(controls: controls, connected: connected, busy: busy, pending: pending,
                        onChange: { _, _ in sent += 1 })
        }
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(draft.canApply(controls: controls, connected: true, busy: false,
                                      pending: [:], callbackAvailable: false))
        draft.apply(controls: controls, connected: true, busy: false, pending: [:], onChange: nil)
        draft.reconcile(nil)
        XCTAssertEqual(draft.displayedText(nil), "20000", "Disconnect keeps the draft, not invented confirmation")
        XCTAssertEqual(SpeechThresholdDraft.confirmedLabel(nil), "No reported cutoff available; waiting for VoiceLayer.")
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("short_limit_chars", controls: locked, pending: [:]))
        XCTAssertEqual(SpeechThresholdDraft.confirmedLabel(locked.shortLimit),
                       "Last reported effective cutoff: 600 characters · Environment override; saved value not reported.")
        let defaults = try XCTUnwrap(SpeechControlsState(controls: Self.thresholdControls(source: "default")))
        XCTAssertTrue(SpeechThresholdDraft.confirmedLabel(defaults.shortLimit).contains("no saved value reported"))
        XCTAssertEqual(SpeechThresholdDraft.confirmedLabel(defaults.shortLimit),
                       "Last reported cutoff: 400 characters · Default at that report; no saved value reported.")
    }

}
