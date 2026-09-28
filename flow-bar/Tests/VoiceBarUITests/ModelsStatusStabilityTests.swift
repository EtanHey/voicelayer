@testable import VoiceBarUI
import XCTest

/// B1 reviewer finding (plan README § "Found by the B1 reviewer"): the footer and popover flickered
/// "Starting…" after EVERY dictation, because recording→idle reset the Models state to `.loading` while a
/// health refresh was in flight. And `.unavailable` said "Not connected" even when VoiceLayer was
/// connected but its health reply couldn't be read.
final class ModelsStatusStabilityTests: XCTestCase {
    private static let health: [String: Any] = [
        "type": "health",
        "recording_state": "idle",
        "model_status": [
            "configured_model": ["name": "large-v3-turbo", "installed": true],
            "residency": "loaded",
            "configured_effort": "accurate",
        ],
    ]

    private func readyState() -> VoiceState {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.setConnectionStatus(true)
        state.handleEvent(Self.health)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Ready")
        return state
    }

    func testADictationNeverFlashesStartingInTheFooter() {
        let state = readyState()
        var seen: [String] = []
        for event: [String: Any] in [
            ["type": "state", "state": "recording"],
            ["type": "state", "state": "transcribing"],
            ["type": "state", "state": "idle"],
        ] {
            state.handleEvent(event)
            seen.append(VoiceBarFooterPresentation.resolve(state: state).status)
        }
        XCTAssertFalse(seen.contains("Starting…"), "statuses across a dictation: \(seen)")
        XCTAssertEqual(seen.last, "Ready", "idle keeps the last-known health until the refresh answers")
        XCTAssertTrue(state.modelsSettingsState.isBusy, "effort still waits for the fresh health reply")
        XCTAssertEqual(state.modelsSettingsState.busyReason, "Checking VoiceLayer…")
        state.handleEvent(Self.health)
        XCTAssertFalse(state.modelsSettingsState.isBusy)
    }

    /// #162 review nit: an unreadable daemon went "Status unreadable → Starting… → Status unreadable"
    /// around every dictation; it keeps its last-known status the same way `.available` does.
    func testAnUnreadableDaemonKeepsItsStatusAcrossADictationAndARefresh() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "recording_state": "idle"])
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Status unreadable")

        var seen: [String] = []
        for event: [String: Any] in [
            ["type": "state", "state": "recording"],
            ["type": "state", "state": "transcribing"],
            ["type": "state", "state": "idle"],
        ] {
            state.handleEvent(event)
            seen.append(VoiceBarFooterPresentation.resolve(state: state).status)
        }
        XCTAssertFalse(seen.contains("Starting…"), "statuses: \(seen)")
        XCTAssertEqual(seen.last, "Status unreadable")

        state.refreshModelsSettingsStatus()
        XCTAssertEqual(state.modelsSettingsState.availability, .unreadable)
    }

    func testARefreshKeepsTheLastKnownStatusWhileItIsInFlight() {
        let state = readyState()
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }

        state.refreshModelsSettingsStatus()

        XCTAssertEqual(sent.last?["cmd"] as? String, "health", "the refresh is still requested")
        XCTAssertEqual(state.modelsSettingsState.availability, .available)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Ready")
    }

    func testStartingShowsOnlyOnARealReconnect() {
        let state = readyState()
        state.setConnectionStatus(false)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Disconnected")
        state.setConnectionStatus(true)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Starting…")
    }

    func testDisconnectedAndUnreadableHealthAreToldApart() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.setConnectionStatus(false)
        XCTAssertEqual(state.modelsSettingsState.availability, .disconnected)

        state.setConnectionStatus(true)
        state.handleEvent(["type": "health", "remote_stt_configured": false])
        XCTAssertEqual(state.modelsSettingsState.availability, .unreadable)

        let footer = VoiceBarFooterPresentation.resolve(state: state)
        XCTAssertEqual(footer.status, "Status unreadable", "connected, so neither Disconnected nor Starting…")
        XCTAssertFalse(footer.isReady)
    }

    func testModelsCopyIsTruthfulForEachAvailability() {
        let unreadable = ModelsSettingsState(healthEvent: ["type": "health"])
        XCTAssertEqual(unreadable.availability, .unreadable)
        XCTAssertEqual(ModelsSettingsView.effortDisabledReason(for: unreadable),
                       "VoiceLayer is connected, but its status couldn't be read")
        XCTAssertEqual(ModelsSettingsView.processingPlaceholder(for: unreadable),
                       "VoiceLayer is connected, but its status couldn't be read. These appear when it answers.")

        XCTAssertEqual(ModelsSettingsView.effortDisabledReason(for: .disconnected),
                       "Available when VoiceLayer is running")
        XCTAssertEqual(ModelsSettingsView.processingPlaceholder(for: .disconnected),
                       "VoiceLayer isn't connected. These appear when it reconnects.")
    }
}
