@testable import VoiceBarUI
import XCTest

/// P1: real Processing toggles. The daemon persists them; env-set flags are shown, locked.
final class ProcessingTogglesTests: XCTestCase {
    private static func controls(
        polish: (String, Any, String) = ("default", NSNull(), "on"),
        outro: (String, Any, Bool) = ("default", NSNull(), true),
        chunks: (String, Any, Bool) = ("default", NSNull(), false),
        boundaries: (String, Any, Bool) = ("settings", NSNull(), true)
    ) -> [String: Any] {
        [
            "model_polish": ["source": polish.0, "raw": polish.1, "effective": polish.2],
            "outro_gate": ["source": outro.0, "raw": outro.1, "effective": outro.2],
            "smart_chunks": ["source": chunks.0, "raw": chunks.1, "effective": chunks.2],
            "smart_boundaries": ["source": boundaries.0, "raw": boundaries.1, "effective": boundaries.2],
        ]
    }

    private static func health(_ controls: [String: Any]) -> [String: Any] {
        [
            "type": "health",
            "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
                "residency": "loaded", "active_model": "large-v3-turbo",
                "configured_effort": "accurate", "active_effort": "accurate",
            ] as [String: Any],
            "polish_controls": controls,
        ]
    }

    func testParsesTheSettingsSource() throws {
        let state = try XCTUnwrap(PolishControlsState(healthEvent: Self.health(Self.controls())))
        XCTAssertEqual(state.smartBoundaries.source, .settings)
        XCTAssertTrue(state.smartBoundaries.effective)
        // A settings source must not carry a raw env value.
        XCTAssertNil(PolishControlsState(healthEvent: Self.health(Self.controls(boundaries: ("settings", "1", true)))))
    }

    func testRowsSayWhatEachDoesAndLockEnvSetFlags() throws {
        let state = try XCTUnwrap(PolishControlsState(healthEvent: Self.health(Self.controls(
            outro: ("environment", "0", false)
        ))))
        let rows = ModelsSettingsView.processingRows(for: state)

        XCTAssertEqual(rows.map(\.key), [.modelPolish, .outroGate, .smartChunks, .smartBoundaries])
        XCTAssertEqual(rows.map(\.isOn), [true, false, false, true])
        XCTAssertEqual(rows.map(\.experimental), [false, false, true, true])
        XCTAssertTrue(rows.allSatisfy { !$0.line.isEmpty })
        XCTAssertNil(rows[0].lockedReason)
        XCTAssertEqual(rows[1].lockedReason, "Set by VOICELAYER_STT_OUTRO_GATE")
        XCTAssertNil(rows[3].lockedReason, "a flag from the settings file is the user's to change")
    }

    func testPolishPreviewModeIsShownButNotAToggleState() throws {
        let state = try XCTUnwrap(PolishControlsState(healthEvent: Self.health(Self.controls(
            polish: ("environment", "shadow", "shadow")
        ))))
        let polish = try XCTUnwrap(ModelsSettingsView.processingRows(for: state).first)
        XCTAssertEqual(polish.lockedReason, "Preview only (set by QA_VOICE_STT_POLISH)")
    }

    func testToggleSendsTheCommandAndTheAckUpdatesTheRow() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(Self.health(Self.controls()))

        state.setProcessingSetting(.outroGate, false)
        let command = try XCTUnwrap(commands.last)
        XCTAssertEqual(command["cmd"] as? String, "set_processing_setting")
        XCTAssertEqual(command["key"] as? String, "outro_gate")
        XCTAssertEqual(command["value"] as? Bool, false)
        XCTAssertEqual(state.processingPending[.outroGate], false)

        state.handleEvent([
            "type": "ack", "command": "set_processing_setting", "outcome": "accept",
            "id": command["id"] as Any,
            "polish_controls": Self.controls(outro: ("settings", NSNull(), false)),
        ])
        XCTAssertNil(state.processingPending[.outroGate])
        XCTAssertEqual(state.modelsSettingsState.polishControls?.outroGate.source, .settings)
        XCTAssertEqual(state.modelsSettingsState.polishControls?.outroGate.effective, false)
        XCTAssertNil(state.processingNotice)
    }

    func testRejectShowsWhyAndDisconnectDropsThePendingToggle() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        state.handleEvent(Self.health(Self.controls()))

        state.setProcessingSetting(.smartChunks, true)
        state.handleEvent([
            "type": "ack", "command": "set_processing_setting", "outcome": "reject",
            "id": commands.last?["id"] as Any, "reason": "busy",
        ])
        XCTAssertNil(state.processingPending[.smartChunks])
        XCTAssertEqual(state.processingNotice, "Couldn't change Smart chunks - busy")

        state.setProcessingSetting(.smartChunks, true)
        XCTAssertEqual(state.processingPending[.smartChunks], true)
        state.setConnectionStatus(false)
        XCTAssertTrue(state.processingPending.isEmpty)
    }
}
