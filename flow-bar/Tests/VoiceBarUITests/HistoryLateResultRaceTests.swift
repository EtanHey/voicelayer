@testable import VoiceBarUI
import XCTest

/// #186 review round 3 (High): a late History result must not touch a new dictation's deferred final. With a
/// positive transcribing display floor, the new dictation's final is deferred; a late archived result arriving
/// inside that window used to cancel and replace the single deferred task, losing the new dictation's words.
@MainActor
final class HistoryLateResultRaceTests: XCTestCase {
    private static let archivedPath = "/tmp/fixture/recordings/2025-12-31T00-00-00/audio.wav"
    private static let newPath = "/tmp/fixture/recordings/2026-01-02T00-00-00/audio.wav"
    private static let newText = "Synthetic new dictation"
    private static let archivedText = "Synthetic re-transcribed archive text"

    private struct Harness {
        let state: VoiceState
        let pasted: () -> [String]
        let archiveChanges: () -> [String?]
    }

    /// Accepted History request → an unrelated client's error cleans it up → a new bar-owned dictation reaches
    /// `transcribing`, so its final lands inside the positive display floor.
    private func startNewDictationAfterAbandonedHistoryRequest(
        seededEntries: [RecentTranscriptionEntry] = []
    ) throws -> Harness {
        var entries = seededEntries
        let state = VoiceState(
            recentTranscriptionsLoader: { entries.map(\.text) },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { entries },
            recentTranscriptionEntriesSaver: { entries = $0 }
        )
        state.minimumTranscribingDisplayDuration = 0.08
        state.pasteConfirmationDelay = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        var archiveChanges: [String?] = []
        state.sendCommand = { sentCommand = $0 }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.onHistoryArchiveChange = { archiveChanges.append($0) }

        state.retranscribeHistoryEntry(recordingPath: Self.archivedPath)
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent(["type": "ack", "command": "retranscribe_recording", "outcome": "accept", "id": id])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "error", "message": "Synthetic error from another client"])

        state.record()
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.handleEvent(["type": "state", "state": "transcribing"])
        return Harness(state: state, pasted: { pastedTexts }, archiveChanges: { archiveChanges })
    }

    private func sendNewFinal(to state: VoiceState, extra: [String: Any] = [:]) {
        state.handleEvent(
            ["type": "transcription", "text": Self.newText, "recording_path": Self.newPath]
                .merging(extra) { _, new in new }
        )
    }

    private func sendLateArchivedFinal(
        to state: VoiceState,
        text: String = HistoryLateResultRaceTests.archivedText,
        extra: [String: Any] = [:]
    ) {
        state.handleEvent(
            ["type": "transcription", "text": text, "recording_path": Self.archivedPath]
                .merging(extra) { _, new in new }
        )
    }

    private func assertNewDictationLanded(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let state = harness.state
        XCTAssertEqual(
            harness.pasted(),
            [Self.newText],
            "the new dictation pastes exactly once, never the old text",
            file: file,
            line: line
        )
        XCTAssertEqual(state.latestReusableTranscript, Self.newText, file: file, line: line)
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, Self.newPath, file: file, line: line)
        XCTAssertNotEqual(
            state.mode,
            .transcribing,
            "the new dictation's final ended its transcribing state",
            file: file,
            line: line
        )
    }

    func testALateHistoryResultDoesNotDropANewDictationsDeferredFinal() async throws {
        let harness = try startNewDictationAfterAbandonedHistoryRequest()
        // Inside the display floor: the new final is deferred…
        sendNewFinal(to: harness.state)
        // …and the old History result lands before the deferral fires.
        sendLateArchivedFinal(to: harness.state)
        try? await Task.sleep(for: .milliseconds(300))

        assertNewDictationLanded(harness)
        XCTAssertFalse(harness.state.recentTranscriptionEntries.contains { $0.recordingPath == Self.archivedPath })
    }

    func testALateHistoryResultBeforeTheNewFinalLeavesTheNewFinalIntact() async throws {
        let harness = try startNewDictationAfterAbandonedHistoryRequest()
        sendLateArchivedFinal(to: harness.state)
        XCTAssertEqual(harness.state.mode, .transcribing, "the late archived result does not end the new dictation")
        sendNewFinal(to: harness.state)
        try? await Task.sleep(for: .milliseconds(300))

        assertNewDictationLanded(harness)
        XCTAssertFalse(harness.state.recentTranscriptionEntries.contains { $0.recordingPath == Self.archivedPath })
        // Deferred behind the floor, the old result was the task the new final replaced: its rewrite never ran.
        XCTAssertTrue(harness.archiveChanges().contains(Self.archivedPath), "the old result still rewrote its row")
    }

    func testALateHistoryResultInsideTheWindowRewritesOnlyItsOwnRow() async throws {
        let harness = try startNewDictationAfterAbandonedHistoryRequest(seededEntries: [
            RecentTranscriptionEntry(
                text: "Synthetic original archive text",
                recordingPath: Self.archivedPath,
                createdAt: Date(timeIntervalSince1970: 1_767_139_200)
            ),
        ])
        sendNewFinal(to: harness.state)
        sendLateArchivedFinal(to: harness.state)
        // Handled at once, not held behind the display floor, and without pasting.
        XCTAssertEqual(harness.state.recentTranscriptionEntries.first?.recordingPath, Self.archivedPath)
        XCTAssertEqual(harness.state.recentTranscriptionEntries.first?.text, Self.archivedText)
        XCTAssertEqual(harness.pasted(), [])
        XCTAssertTrue(harness.archiveChanges().contains(Self.archivedPath))
        try? await Task.sleep(for: .milliseconds(300))

        assertNewDictationLanded(harness)
        XCTAssertEqual(
            harness.state.recentTranscriptionEntries.map(\.recordingPath),
            [Self.newPath, Self.archivedPath]
        )
        XCTAssertEqual(harness.state.recentTranscriptionEntries.last?.text, Self.archivedText)
        XCTAssertEqual(
            harness.state.recentTranscriptionEntries.last?.createdAt,
            Date(timeIntervalSince1970: 1_767_139_200),
            "a re-transcription keeps the time the row was dictated"
        )
    }

    func testAnEmptyLateHistoryResultDoesNotFailTheNewDictation() async throws {
        let harness = try startNewDictationAfterAbandonedHistoryRequest()
        sendNewFinal(to: harness.state)
        // An old request can come back empty; it belongs to no live capture, so it must not fail this one.
        sendLateArchivedFinal(to: harness.state, text: "  ")
        XCTAssertNotEqual(harness.state.mode, .error)
        try? await Task.sleep(for: .milliseconds(300))

        assertNewDictationLanded(harness)
        XCTAssertNotEqual(harness.state.mode, .error)
        XCTAssertFalse(harness.archiveChanges().contains(Self.archivedPath), "an empty result rewrites nothing")
    }

    func testALateHistoryResultLeavesTheNewDictationsPolishMetadataAndPartialAlone() async throws {
        let harness = try startNewDictationAfterAbandonedHistoryRequest()
        harness.state.handleEvent(["type": "transcription", "text": "Synthetic new partial", "partial": true])
        sendLateArchivedFinal(to: harness.state, text: "Synthetic archive partial", extra: ["partial": true])
        XCTAssertEqual(harness.state.transcript, "Synthetic new partial")

        sendNewFinal(to: harness.state, extra: ["polished": true, "polish_reason": "synthetic-new"])
        sendLateArchivedFinal(to: harness.state, extra: ["polished": false, "polish_reason": "synthetic-archive"])
        XCTAssertEqual(harness.state.lastTranscriptionPolished, true)
        XCTAssertEqual(harness.state.lastTranscriptionPolishReason, "synthetic-new")
        try? await Task.sleep(for: .milliseconds(300))

        assertNewDictationLanded(harness)
        XCTAssertEqual(harness.state.lastTranscriptionPolished, true)
        XCTAssertEqual(harness.state.lastTranscriptionPolishReason, "synthetic-new")
    }
}
