@testable import VoiceBar
import XCTest

final class VoiceStateCommandModeTests: XCTestCase {
    func testCommandModeApplyUsesNativeSelectionHelper() {
        let state = VoiceState()
        var appliedText: String?
        state.commandModeApplyHandler = { text in
            appliedText = text
            return .axVerified("Applied to selection")
        }

        state.handleEvent([
            "type": "command_mode",
            "phase": "applying",
            "operation": "replace_selection",
            "replacement_text": "const answer = 42",
            "prompt": "Rewrite selection",
        ])

        XCTAssertEqual(appliedText, "const answer = 42")
        XCTAssertEqual(state.commandModeState?.phase, .done)
        XCTAssertEqual(state.confirmationText, "Applied to selection")
    }

    func testCommandModeApplyFallsBackToClipboardStatus() {
        let state = VoiceState()
        state.commandModeApplyHandler = { _ in
            .clipboardFallback("Pasted fallback")
        }

        state.handleEvent([
            "type": "command_mode",
            "phase": "applying",
            "operation": "replace_selection",
            "replacement_text": "fallback text",
            "prompt": "Rewrite selection",
        ])

        XCTAssertEqual(state.commandModeState?.phase, .fallback)
        XCTAssertEqual(state.confirmationText, "Pasted fallback")
    }

    func testClipMarkerEventsAreStoredForThePillAndPanel() {
        let state = VoiceState()

        state.handleEvent([
            "type": "clip_marker",
            "marker_id": "clip-22",
            "label": "Action item",
            "source": "command",
            "status": "marked",
        ])

        XCTAssertEqual(state.activeClipMarker?.id, "clip-22")
        XCTAssertEqual(state.activeClipMarker?.label, "Action item")
        XCTAssertEqual(state.activeClipMarker?.source, "command")
    }

    func testCommandModeEventRequestsPanelLayoutRefresh() {
        assertVoiceStateEventTriggersPanelLayoutRefresh([
            "type": "command_mode",
            "phase": "capturing",
            "operation": "replace_selection",
            "prompt": "Rewrite selection",
        ])
    }

    func testClipMarkerEventRequestsPanelLayoutRefresh() {
        assertVoiceStateEventTriggersPanelLayoutRefresh([
            "type": "clip_marker",
            "marker_id": "clip-22",
            "label": "Action item",
            "source": "command",
            "status": "marked",
        ])
    }
}

extension XCTestCase {
    func assertVoiceStateEventTriggersPanelLayoutRefresh(
        _ event: [String: Any],
        state: VoiceState = VoiceState(),
        timeout: TimeInterval = 1
    ) {
        let layoutChanged = expectation(description: "panel layout refreshed")
        layoutChanged.assertForOverFulfill = false
        state.onPanelLayoutChange = {
            layoutChanged.fulfill()
        }

        state.handleEvent(event)

        wait(for: [layoutChanged], timeout: timeout)
    }
}
