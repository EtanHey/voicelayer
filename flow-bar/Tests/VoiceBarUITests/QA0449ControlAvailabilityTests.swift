import AppKit
@testable import VoiceBarUI
import XCTest

@MainActor
final class QA0449ControlAvailabilityTests: XCTestCase {
    private func state() -> VoiceState {
        VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
    }

    func testMicrophonePreferenceEditsLockForOpeningOpenAndPausedCapture() {
        let s = state()
        s.isConnected = true
        s.sendCommand = { _ in }
        XCTAssertNil(s.microphonePriorityDisabledReason)
        s.record(pressToTalk: true)
        XCTAssertFalse(s.captureLive, "fixture: opening before the first audio frame")
        XCTAssertEqual(s.microphonePriorityDisabledReason, "Finish recording to change microphones")
        s.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        s.handleEvent(["type": "audio_level", "rms": 0.2])
        XCTAssertTrue(s.captureLive)
        XCTAssertEqual(s.microphonePriorityDisabledReason, "Finish recording to change microphones")
        s.setRecordingPaused(true)
        XCTAssertTrue(s.isRecordingPaused)
        XCTAssertEqual(s.microphonePriorityDisabledReason, "Finish recording to change microphones")
        s.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertNil(s.microphonePriorityDisabledReason)
        s.mode = .transcribing
        XCTAssertNil(s.microphonePriorityDisabledReason, "the formal policy permits editing after capture closes")
    }

    func testMicrophonePointerDropAndAXShareTheExplainedLockAndHandlersRecheckIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"))
        let app = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"))
        XCTAssertTrue(ui.contains(".background(PillControlTooltip(text: microphoneEditReason))"))
        XCTAssertTrue(ui.contains(".accessibilityHint(microphoneEditReason"))
        XCTAssertTrue(ui.contains("if microphoneEditReason == nil {"), "locked named AX actions are omitted")
        XCTAssertTrue(ui.contains("if let uid = row.uid, row.canPrioritize, microphoneEditReason == nil"))
        for call in ["makingDefaultUIDs", "droppingVisibleUIDs", "reorderedVisibleUIDs"] {
            XCTAssertTrue(ui.contains("guard microphoneEditReason == nil, " + (call == "droppingVisibleUIDs" ? "let uid, " : "")
                + "let uids = microphoneSnapshot." + call), "handler rechecks " + call)
        }
        XCTAssertTrue(app.contains("guard voiceState.microphonePriorityDisabledReason == nil else { return }"))
    }
}
