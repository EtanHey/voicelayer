@testable import VoiceBarUI
import XCTest

final class ModelsSettingsStateTests: XCTestCase {
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
}
