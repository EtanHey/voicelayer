import Foundation
@testable import VoiceBarUI
import XCTest

@MainActor
final class PrivacyDiagnosticTests: XCTestCase {
    func testPRIV1FinalTranscriptLogsPresenceAndKeepsFullPathInHistory() throws {
        try checkResult("final")
    }

    func testPRIV1LateArchivedResultLogsPresenceAndKeepsArchiveIdentity() throws {
        try checkResult("late")
    }

    func testPRIV1EmptyLateResultLogsPresenceWithoutItsPath() throws {
        try checkResult("late-empty")
    }

    func testPRIV1RejectedHistoryRequestDoesNotLogItsPath() throws {
        try checkResult("rejected")
    }

    private func checkResult(_ scenario: String) throws {
        let path = "/Users/PRIVATE_OWNER/recordings/2026-10-16T00-00-00/audio.wav"
        let text = "PRIVATE_TRANSCRIPT שלום 🔐"
        var rows: [RecentTranscriptionEntry] = []
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { rows = $0 })
        state.mode = .idle
        state.minimumTranscribingDisplayDuration = 0
        var diagnostics: [(String, [String: String])] = []
        var journal: [(String, [String: String])] = []
        state.diagnosticLogger = { diagnostics.append(($0, $1)) }
        state.controlLayerEventWriter = { journal.append(($0, $1)) }
        if scenario != "final" {
            var command: [String: Any]?
            state.sendCommand = { command = $0 }
            state.retranscribeHistoryEntry(recordingPath: path)
            XCTAssertEqual(command?["audio_path"] as? String, path)
            let id = try XCTUnwrap(command?["id"] as? String)
            state.handleEvent(["type": "ack", "command": "retranscribe_recording", "id": id,
                               "outcome": scenario == "rejected" ? "reject" : "accept", "reason": "Rejected " + path])
            if scenario != "rejected" {
                state.handleEvent(["type": "state", "state": "transcribing"])
                state.handleEvent(["type": "error", "message": "Synthetic failure before late result"])
            }
        }
        if scenario != "rejected" {
            state.handleEvent(["type": "transcription", "text": scenario == "late-empty" ? "" : text,
                               "recording_path": path, "recording_created_at": "2026-10-16T00:00:00Z"])
            let event = scenario == "final" ? "transcription_final" : "transcription_final_archived_" + (scenario == "late" ? "late" : "late_empty")
            let details = try XCTUnwrap(diagnostics.first { $0.0 == event }?.1)
            XCTAssertEqual(details["hasRecordingPath"], "true")
            if scenario != "late-empty" {
                XCTAssertTrue(rows.contains { $0.recordingPath == path && $0.text == text })
            }
            if scenario == "final" {
                XCTAssertEqual(journal.first { $0.0 == event }?.1["hasRecordingPath"], "true")
            }
        }
        for (_, details) in diagnostics + journal {
            let output = String(describing: details) // The same details feed NSLog and the ControlLayer writer.
            XCTAssertFalse(output.contains(path), output)
            XCTAssertFalse(output.contains("PRIVATE_OWNER"), output)
            XCTAssertFalse(output.contains(text), output)
        }
    }
}
