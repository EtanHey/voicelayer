import Foundation
import Darwin
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
        let nonce = UUID().uuidString
        let home = "CANARY-HOME-\(nonce)"
        let path = "/Users/\(home)/recordings/2026-10-16T00-00-00/audio.wav"
        let text = "CANARY-TXT-\(nonce) שלום 🔐"
        // Capture direct NSLog/stderr as well as the structured diagnostic and
        // ControlLayer seams below. This never starts the app or a live socket.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(nonce).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(saved); try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        fflush(stderr)
        guard dup2(log.fileDescriptor, STDERR_FILENO) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            fflush(stderr)
            dup2(saved, STDERR_FILENO)
            do {
                let output = try String(contentsOf: logURL, encoding: .utf8)
                XCTAssertTrue(output.contains("[privacy-fixture]"), "NSLog capture produced no diagnostics")
                XCTAssertFalse(output.contains(home), "Home canary escaped through stderr")
                XCTAssertFalse(output.contains(text), "Text canary escaped through stderr")
            } catch { XCTFail("Cannot read captured diagnostics: \(error)") }
        }
        NSLog("[privacy-fixture] capture-ready") // Rejected requests may intentionally emit nothing.
        var rows: [RecentTranscriptionEntry] = []
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { rows = $0 })
        state.mode = .idle
        state.minimumTranscribingDisplayDuration = 0
        var diagnostics: [(String, [String: String])] = []
        var journal: [(String, [String: String])] = []
        state.diagnosticLogger = {
            diagnostics.append(($0, $1))
            NSLog("[privacy-fixture] %@ %@", $0, String(describing: $1))
        }
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
        for (event, details) in diagnostics + journal {
            let output = event + String(describing: details) // Same event/details feed NSLog and ControlLayer.
            XCTAssertFalse(output.contains(path), output)
            XCTAssertFalse(output.contains(home), output)
            XCTAssertFalse(output.contains(text), output)
        }
    }
}
