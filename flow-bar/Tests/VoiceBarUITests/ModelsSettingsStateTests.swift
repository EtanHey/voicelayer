@testable import VoiceBarUI
import XCTest

final class ModelsSettingsStateTests: XCTestCase {
    func testResidencyCommandUsesAckedModelStatusAndClearsOnDisconnect() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(Self.availableHealth)
        state.setWhisperResidency(.loaded)
        XCTAssertEqual(commands.last?["cmd"] as? String, "set_whisper_residency")
        XCTAssertEqual(commands.last?["action"] as? String, "load")
        let id = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent([
            "type": "ack", "command": "set_whisper_residency", "id": id,
            "outcome": "accept",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "installed": true],
                "residency": "loaded", "active_model": "large-v3-turbo",
                "configured_effort": "accurate", "active_effort": "accurate",
            ],
        ])
        XCTAssertEqual(state.modelsSettingsState.residency, .loaded)

        state.setWhisperResidency(.notLoaded)
        XCTAssertEqual(commands.last?["action"] as? String, "unload")
        let unloadID = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent([
            "type": "ack", "command": "set_whisper_residency", "id": unloadID,
            "outcome": "reject", "reason": "not owned",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "installed": true],
                "residency": "loaded", "active_model": "large-v3-turbo",
                "configured_effort": "accurate", "active_effort": "accurate",
            ],
        ])
        XCTAssertEqual(state.modelsSettingsState.residency, .loaded)
        XCTAssertEqual(state.residencyNotice, "not owned")
        state.setConnectionStatus(false)
        XCTAssertEqual(state.modelsSettingsState.availability, .unavailable)
        XCTAssertNil(state.residencyNotice)
    }

    func testPlaybackAndPendingResidencyKeepControlBusyAcrossHealth() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        var playbackHealth = Self.availableHealth
        playbackHealth["queue_depth"] = 1
        state.handleEvent(playbackHealth)
        XCTAssertTrue(state.modelsSettingsState.isBusy)
        var idleHealth = Self.availableHealth
        idleHealth["queue_depth"] = 0
        state.handleEvent(idleHealth)
        XCTAssertFalse(state.modelsSettingsState.isBusy)

        state.handleEvent(["type": "queue", "depth": 1])
        XCTAssertTrue(state.modelsSettingsState.isBusy)
        state.handleEvent(["type": "queue", "depth": 0])
        XCTAssertFalse(state.modelsSettingsState.isBusy)

        state.setWhisperResidency(.notLoaded)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(state.modelsSettingsState.isBusy)
        state.handleEvent(["type": "queue", "depth": 1])
        state.handleEvent(["type": "queue", "depth": 0])
        XCTAssertTrue(state.modelsSettingsState.isBusy)
        state.handleEvent(Self.availableHealth)
        XCTAssertTrue(state.modelsSettingsState.isBusy)
        state.setWhisperResidency(.notLoaded)
        XCTAssertEqual(commands.count, 1)

        for recordingState in ["recording", "transcribing"] {
            let active = VoiceState()
            active.setConnectionStatus(true)
            var busyHealth = Self.availableHealth
            busyHealth["recording_state"] = recordingState
            active.handleEvent(busyHealth)
            active.handleEvent(["type": "queue", "depth": 1])
            active.handleEvent(["type": "queue", "depth": 0])
            XCTAssertTrue(active.modelsSettingsState.isBusy)
        }
    }

    func testRefreshFailsClosedOfflineAndSendsOnlyReadOnlyHealthWhenConnected() {
        let voiceState = VoiceState()
        var commands: [[String: Any]] = []
        voiceState.sendCommand = { commands.append($0) }

        voiceState.refreshModelsSettingsStatus()
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .unavailable)
        XCTAssertTrue(commands.isEmpty)

        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        voiceState.refreshModelsSettingsStatus()

        XCTAssertEqual(voiceState.modelsSettingsState.availability, .loading)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["cmd"] as? String, "health")
        XCTAssertEqual(commands[0].count, 1)
    }

    func testDisconnectAndReconnectRequireFreshHealthBeforeModelsBecomeAvailable() {
        let health: [String: Any] = [
            "type": "health",
            "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
                "residency": "loaded",
                "active_model": "large-v3-turbo",
                "configured_effort": "accurate",
                "active_effort": "accurate",
            ],
        ]
        let voiceState = VoiceState()

        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(health)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .available)
        XCTAssertFalse(voiceState.modelsSettingsState.isBusy)

        voiceState.setConnectionStatus(false)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .unavailable)
        XCTAssertTrue(voiceState.modelsSettingsState.isBusy)

        voiceState.setConnectionStatus(true)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .loading)
        XCTAssertTrue(voiceState.modelsSettingsState.isBusy)

        voiceState.handleEvent(health)
        XCTAssertEqual(voiceState.modelsSettingsState.availability, .available)
        XCTAssertFalse(voiceState.modelsSettingsState.isBusy)
    }

    func testParsesTruthfulConfiguredActiveAndBusyState() {
        let event: [String: Any] = [
            "type": "health",
            "recording_state": "transcribing",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 1_617_000_000, "installed": true],
                "residency": "loaded",
                "active_model": "base.en",
                "configured_effort": "accurate",
                "active_effort": "balanced",
            ],
        ]
        let voiceState = VoiceState()
        voiceState.handleEvent(event)
        let state = voiceState.modelsSettingsState
        XCTAssertEqual(state.availability, .available)
        XCTAssertEqual(state.configuredModelName, "large-v3-turbo")
        XCTAssertEqual(state.configuredModelSizeBytes, 1_617_000_000)
        XCTAssertEqual(state.isInstalled, true)
        XCTAssertEqual(state.residency, .loaded)
        XCTAssertEqual(state.activeModelName, "base.en")
        XCTAssertEqual(state.configuredEffort, .accurate)
        XCTAssertEqual(state.activeEffort, .balanced)
        XCTAssertTrue(state.isBusy)
    }

    func testHealthyWithoutProvenanceKeepsActiveIdentityUnknown() {
        let state = ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
                "residency": "loaded", "active_model": NSNull(),
                "configured_effort": "fast", "active_effort": NSNull(),
            ],
        ])
        XCTAssertEqual(state.residency, .loaded)
        XCTAssertNil(state.activeModelName)
        XCTAssertNil(state.activeEffort)
        XCTAssertFalse(state.isBusy)
    }

    func testMissingStatusFailsClosedAsUnavailableAndUnknown() {
        let state = ModelsSettingsState(healthEvent: ["type": "health", "recording_state": "idle"])
        XCTAssertEqual(state.availability, .unavailable)
        XCTAssertEqual(state.residency, .unknown)
        XCTAssertTrue(state.isBusy)
    }

    func testPolishControlsRequireAuthoritativeHealthAndClearOnDisconnect() {
        let voiceState = VoiceState()
        voiceState.setConnectionStatus(true)
        voiceState.handleEvent(Self.availableHealth)
        XCTAssertNil(voiceState.modelsSettingsState.polishControls)

        var health = Self.availableHealth
        health["polish_controls"] = [
            "model_polish": ["source": "environment", "raw": "shadow", "effective": "shadow"],
            "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
            "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            "smart_boundaries": ["source": "default", "raw": NSNull(), "effective": false],
        ]
        voiceState.handleEvent(health)
        XCTAssertEqual(voiceState.modelsSettingsState.polishControls?.modelPolish.effective, .shadow)
        XCTAssertEqual(voiceState.modelsSettingsState.polishControls?.modelPolish.source, .environment)
        XCTAssertEqual(voiceState.modelsSettingsState.polishControls?.outroGate.effective, true)
        XCTAssertEqual(voiceState.modelsSettingsState.polishControls?.smartChunks.effective, false)

        voiceState.setConnectionStatus(false)
        XCTAssertNil(voiceState.modelsSettingsState.polishControls)
    }

    private static let availableHealth: [String: Any] = [
        "type": "health",
        "recording_state": "idle",
        "model_status": [
            "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
            "residency": "loaded",
            "active_model": "large-v3-turbo",
            "configured_effort": "accurate",
            "active_effort": "accurate",
        ],
    ]
}
