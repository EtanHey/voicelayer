import XCTest
@testable import VoiceBarUI

final class SettingsHistoryDiagnosticsTests: XCTestCase {
    func testSelectionChangeAppliesResultDefaultAndClearsTechnicalExpansion() {
        var state = SettingsHistoryDiagnosticsDisclosure(selection: "2026-11-01/a")
        XCTAssertFalse(state.expanded)
        state.expanded = false
        state.detailsExpanded = true
        state.select("2026-11-01/a")
        XCTAssertFalse(state.expanded, "same-entry refresh preserves deliberate collapse")
        XCTAssertTrue(state.detailsExpanded)
        state.select("2026-11-01/b", defaultExpanded: true)
        XCTAssertTrue(state.expanded, "new entry diagnostics remain accessible")
        XCTAssertFalse(state.detailsExpanded, "private error expansion does not cross selections")
        XCTAssertEqual(state.selection, "2026-11-01/b")
    }

    func testRecordingObservationsDoNotInventAttemptOutcomes() {
        var log = SettingsHistoryRunLog()
        let path = "/synthetic/audio.wav"
        log.begin(id: "failed", path: path)
        log.observe(["type": "error", "message": "Could not retranscribe archived recording \(path). Synthetic failure"])
        log.begin(id: "next", path: path)
        log.observe(["type": "transcription", "recording_path": path, "text": "Synthetic result"])
        XCTAssertEqual(log.runs.map(\.outcome), [.unknown, .unknown])
        XCTAssertNotNil(log.runs[0].recordingObservation)
        XCTAssertNotNil(log.runs[1].recordingObservation)
    }

    func testGenericErrorAndIdleNeverInferFailureOrSuccessFromSavedText() {
        var log = SettingsHistoryRunLog()
        log.begin(id: "unknown", path: "/synthetic/audio.wav")
        log.observe(["type": "error", "message": "Another client failed"])
        log.observe(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertEqual(log.runs[0].outcome, .unknown)
    }
    func testExactRejectionSurvivesPriorUnattributedObservations() {
        let path = "/synthetic/audio.wav"
        let events: [[String: Any]] = [
            ["type": "transcription", "recording_path": path, "text": "Foreign or old result"],
            ["type": "error", "message": "Could not retranscribe archived recording \(path). Foreign or old error"],
            ["type": "error", "message": "Unrelated client error"]
        ]
        for event in events {
            var log = SettingsHistoryRunLog()
            log.begin(id: "current", path: path)
            log.observe(event)
            log.observe(["type": "ack", "command": "retranscribe_recording", "id": "current", "outcome": "reject", "reason": "Synthetic busy"])
            XCTAssertEqual(log.runs[0].outcome, .rejected)
            XCTAssertEqual(log.runs[0].detail, "Synthetic busy")
        }
    }
    func testLatePathOnlyResultCannotCompleteNewOrAcknowledgedAttempt() {
        let path = "/synthetic/audio.wav"
        var log = SettingsHistoryRunLog()
        log.begin(id: "old", path: path)
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "old", "outcome": "accept"])
        log.observe(["type": "transcription", "recording_path": path, "text": "Old result"])
        log.begin(id: "new", path: path)
        log.observe(["type": "transcription", "recording_path": path, "text": "Duplicate old result"])
        XCTAssertEqual(log.runs[0].outcome, .unknown)
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "new", "outcome": "accept"])
        log.observe(["type": "transcription", "recording_path": path, "text": "Still lacks attempt identity"])
        XCTAssertEqual(log.runs[0].outcome, .unknown)
    }
    func testRecordingErrorsRemainVisibleAndObservationRetentionIsBounded() {
        let path = "/synthetic/audio.wav"
        var log = SettingsHistoryRunLog()
        log.begin(id: "current", path: path)
        log.observe(["type": "error", "message": "Could not retranscribe archived recording \(path). Synthetic failure"])
        log.observe(["type": "transcription", "recording_path": path, "text": "Synthetic result"])
        XCTAssertEqual(log.runs[0].recordingObservations.count, 2)
        XCTAssertTrue(log.runs[0].recordingObservations[0].contains("Synthetic failure"))
        for index in 0..<10 {
            log.observe(["type": "error", "message": "Could not retranscribe archived recording \(path). Synthetic failure \(index)"])
        }
        XCTAssertEqual(log.runs[0].recordingObservations.count, 4)
        XCTAssertEqual(log.runs[0].omittedObservationCount, 8)
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "current", "outcome": "reject", "reason": "Exact rejection"])
        log.observe(["type": "ack", "command": "retranscribe_recording", "id": "current", "outcome": "accept"])
        XCTAssertEqual(log.runs[0].outcome, .rejected)
        XCTAssertEqual(log.runs[0].detail, "Exact rejection")
        XCTAssertEqual(log.runs[0].recordingObservations.count, 4)
    }
    func testRedactionExpansionAndInitialCapAlwaysDiscloseOmission() {
        let expanding = String(repeating: "sk-a ", count: 800) + "TAIL-EVIDENCE"
        XCTAssertLessThan(expanding.count, 4096)
        XCTAssertTrue(SettingsHistoryDiagnosticPrivacy.text(expanding).contains("Detail limited"))
        XCTAssertTrue(SettingsHistoryDiagnosticPrivacy.text(String(repeating: "token=x ", count: 1500)).contains("Detail limited"))
        XCTAssertEqual(SettingsHistoryDiagnosticPrivacy.text("Short diagnostic"), "Short diagnostic")
    }
    @MainActor
    func testVoiceStateWiresHistoryRequestAndCorrelatedRejectionWithoutStartingCapture() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false)
        let initialMode = state.mode
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.retranscribeHistoryEntry(recordingPath: "/synthetic/audio.wav")
        state.retranscribeHistoryEntry(recordingPath: "/synthetic/other.wav")
        XCTAssertEqual(commands.count, 1, "presentation observation must preserve the existing one-request guard")
        let id = try XCTUnwrap(commands[0]["id"] as? String)
        XCTAssertEqual(state.historyRunLog.runs.map(\.id), [id])
        state.handleEvent(["type": "ack", "command": "retranscribe_recording", "outcome": "reject", "id": id, "reason": "Synthetic refusal"])
        XCTAssertEqual(state.historyRunLog.runs[0].outcome, .rejected)
        XCTAssertFalse(state.isHistoryRetranscriptionPending)
        XCTAssertEqual(commands[0]["cmd"] as? String, "retranscribe_recording")
        XCTAssertEqual(state.mode, initialMode)
    }

}
