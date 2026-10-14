@testable import VoiceBarUI
import XCTest

final class SpeechReviewRegressionTests: XCTestCase {
    static func health(_ controls: [String: Any]? = SpeechSettingsTests.controls(), idle: Bool = true) -> [String: Any] {
        var event: [String: Any] = ["type": "health", "recording_state": idle ? "idle" : "recording", "queue_depth": 0,
            "model_status": ["residency": "not_loaded", "configured_effort": "accurate", "configured_model": ["installed": true]]]
        if let controls { event["tts_controls"] = controls }
        return event
    }
    func testUnchangedOrMalformedHealthDoesNotRebuildAndRetainsGoodSpeechStatus() {
        let state = VoiceState()
        var rebuilt = 0
        state.onSpeechSettled = { rebuilt += 1 }
        state.setConnectionStatus(true)
        state.handleEvent(Self.health())
        let good = state.speechControls
        rebuilt = 0
        state.handleEvent(Self.health())
        state.handleEvent(Self.health(nil))
        state.handleEvent(Self.health([:]))
        XCTAssertEqual(rebuilt, 0, "health and connection without pending must not replace the Settings root")
        XCTAssertEqual(state.speechControls, good)
    }
    func testPendingEngineAndVoiceDrivePickerAndCloneWarning() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.controls()))
        let row = SpeechSettingsView.displayProfile(.long, controls: controls,
            pending: ["long.engine": .string("clone"), "long.voice": .string("theo-c4")])
        XCTAssertEqual(row?.engine, "clone")
        XCTAssertEqual(row?.voice, "theo-c4")
        XCTAssertEqual(row?.voices, ["theo-c4"])
        XCTAssertTrue(row?.cloneWarning == true)
        let missing = SpeechSettingsView.displayProfile(.long, controls: controls,
            pending: ["long.engine": .string("clone"), "long.voice": .string("new-profile")])
        XCTAssertTrue(missing?.voices.contains("new-profile") == true, "pending selection always has a picker tag")
    }
    @MainActor
    func testPreviewTimeoutKeepsDisabledUntilLateAck() async throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.speechPreviewAckTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        state.handleEvent(Self.health())
        state.previewTTSProfile(.short)
        let id = try XCTUnwrap(commands.last?["id"] as? String)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(state.speechPending["preview"])
        state.previewTTSProfile(.long)
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "preview_tts_profile" }.count, 1)
        state.handleEvent(["type": "ack", "command": "preview_tts_profile", "id": id, "outcome": "accept"])
        XCTAssertNil(state.speechPending["preview"])
    }
    @MainActor
    func testTimedOutPreviewOnlyReleasesOnExplicitIdleDaemonHealth() async throws {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.speechPreviewAckTimeout = .milliseconds(20)
        state.setConnectionStatus(true)
        state.handleEvent(Self.health())
        state.previewTTSProfile(.short)
        try await Task.sleep(for: .milliseconds(150))
        var controls = SpeechSettingsTests.controls()
        controls["preview_active"] = true
        state.handleEvent(Self.health(controls))
        XCTAssertNotNil(state.speechPending["preview"])
        controls["preview_active"] = false
        state.handleEvent(Self.health(controls, idle: false))
        XCTAssertNotNil(state.speechPending["preview"])
        state.handleEvent(Self.health(controls))
        XCTAssertNil(state.speechPending["preview"])
    }
    func testSpeakingAndQueuedPlaybackBlockPreview() {
        for queued in [false, true] {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.setConnectionStatus(true)
            state.handleEvent(Self.health())
            if queued { state.queueDepth = 1 } else { state.mode = .speaking }
            state.previewTTSProfile(.short)
            XCTAssertTrue(commands.isEmpty)
            XCTAssertEqual(state.speechBusyReason, "Speaking…")
        }
    }
    func testEngineEnablementUsesItsOwnCallback() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.controls()))
        XCTAssertFalse(SpeechSettingsView.fieldDisabled("short.engine", controls: controls, pending: [:], callbackAvailable: true))
        XCTAssertTrue(SpeechSettingsView.fieldDisabled("short.engine", controls: controls, pending: [:], callbackAvailable: false))
    }
    func testLatencyNamesActualEngineOriginAndFallbackAndUnknownIsNotInvented() throws {
        var raw = SpeechSettingsTests.controls()
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["short"]?["last_first_audio"] = NSNull()
        profiles["long"]?["last_first_audio"] = ["engine": "edge-tts", "origin": "preview", "fallback": true]
        raw["profiles"] = profiles
        let controls = try XCTUnwrap(SpeechControlsState(controls: raw))
        XCTAssertEqual(controls.profiles[.long]?.latencyLabel, "Last preview: first sound after 0.8 s · Fast voice (fallback)")
        XCTAssertEqual(controls.profiles[.short]?.latencyLabel, "Not measured yet. Press Preview.")
    }
    func testFriendlyCopyAndOneCloneStatusOwner() throws {
        let controls = try XCTUnwrap(SpeechControlsState(controls: SpeechSettingsTests.controls(rateSource: "environment")))
        XCTAssertEqual(SpeechSettingsView.voiceLabel("en-US-JennyNeural"), "Jenny (US)")
        XCTAssertEqual(SpeechSettingsView.engineLabel("edge"), "Fast")
        XCTAssertEqual(SpeechSettingsView.rateLabel("+10%"), "+10% faster")
        XCTAssertEqual(SpeechSettingsView.rateLabel("+0%"), "Normal")
        XCTAssertTrue(SpeechSettingsView.subtitle(.long, limit: 600).contains("600"))
        XCTAssertTrue(SpeechSettingsView.lockFooter(.short, controls: controls)?.contains("applies to both profiles") == true)
        XCTAssertNil(SpeechSettingsView.cloneStatusOwner(controls: controls, pending: [:]))
        XCTAssertEqual(SpeechSettingsView.cloneStatusOwner(controls: controls,
            pending: ["short.engine": .string("clone"), "long.engine": .string("clone")]), .short)
    }
    func testDisconnectOnlyRebuildsWhenSpeechWasPending() {
        let state = VoiceState()
        var rebuilds = 0
        state.sendCommand = { _ in }
        state.onSpeechSettled = { rebuilds += 1 }
        state.setConnectionStatus(true)
        state.handleEvent(Self.health())
        rebuilds = 0
        state.setConnectionStatus(false)
        XCTAssertEqual(rebuilds, 0)
        state.setConnectionStatus(true)
        state.handleEvent(Self.health())
        rebuilds = 0
        state.setTTSSetting("short.rate", .string("+20%"))
        state.setConnectionStatus(false)
        XCTAssertEqual(rebuilds, 1)
    }

}
