@testable import VoiceBarUI
import XCTest

final class ArchiveRecentsTests: XCTestCase {
    private let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let newDate = Date(timeIntervalSince1970: 1_700_000_100)
    private let oldPath = "/tmp/synthetic-old/audio.wav"
    private let newPath = "/tmp/synthetic-new/audio.wav"

    private func state(entries: [RecentTranscriptionEntry]) -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { entries }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0
        state.frontmostAppProvider = { nil }
        state.pasteHandler = { _ in XCTFail("History must never paste")
            return false
        }
        return state
    }

    private func retranscribe(_ state: VoiceState, path: String, text: String, date: Date) {
        state.retranscribeHistoryEntry(recordingPath: path)
        state.handleEvent(["type": "transcription", "text": text, "recording_path": path,
                           "recording_created_at": ISO8601DateFormatter().string(from: date)])
    }

    func testNewestPreviouslyCancelledRecordingBecomesLatestAtItsOriginalTime() {
        let state = state(entries: [RecentTranscriptionEntry(text: "Older synthetic words",
                                                             recordingPath: oldPath, createdAt: oldDate)])
        retranscribe(state, path: newPath, text: "Recovered synthetic words", date: newDate)
        XCTAssertEqual(state.latestReusableTranscript, "Recovered synthetic words")
        XCTAssertEqual(state.recentTranscriptions, ["Recovered synthetic words", "Older synthetic words"])
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, newPath)
        XCTAssertEqual(state.recentTranscriptionEntries.first?.createdAt, newDate)
        XCTAssertEqual(state.lastDictationCardEntry, nil, "History does not claim a fresh dictation card")
    }

    func testMissingOldRecordingInsertsChronologicallyWithoutTakingOverLatest() {
        let state = state(entries: [RecentTranscriptionEntry(text: "Newest synthetic words",
                                                             recordingPath: newPath, createdAt: newDate)])
        retranscribe(state, path: oldPath, text: "Old recovered words", date: oldDate)
        XCTAssertEqual(state.latestReusableTranscript, "Newest synthetic words")
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [newPath, oldPath])
        XCTAssertEqual(state.recentTranscriptionEntries.last?.createdAt, oldDate)
    }

    func testOldEntryIsReplacedInPlaceAndKeepsItsTime() {
        let state = state(entries: [
            RecentTranscriptionEntry(text: "Newest words", recordingPath: newPath, createdAt: newDate),
            RecentTranscriptionEntry(text: "Old words", recordingPath: oldPath, createdAt: oldDate),
        ])
        retranscribe(state, path: oldPath, text: "Corrected old words", date: oldDate)
        XCTAssertEqual(state.latestReusableTranscript, "Newest words")
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [newPath, oldPath])
        XCTAssertEqual(state.recentTranscriptionEntries.last?.createdAt, oldDate)
        XCTAssertEqual(state.recentTranscriptions.last, "Corrected old words")
    }

    func testLegacyEntriesKeepWorkingWhenADatedArchiveEntryIsInserted() {
        let state = state(entries: [RecentTranscriptionEntry(text: "Legacy words without an ID")])
        retranscribe(state, path: newPath, text: "Recovered synthetic words", date: newDate)
        XCTAssertEqual(state.recentTranscriptions, ["Recovered synthetic words", "Legacy words without an ID"])
        XCTAssertNil(state.recentTranscriptionEntries.last?.recordingPath)
        XCTAssertNil(state.recentTranscriptionEntries.last?.createdAt)
    }

    func testLateDatedHistoryResultDoesNotEndOrPasteOverANewDictation() {
        let state = state(entries: [])
        var pasted: [String] = []
        state.pasteHandler = { pasted.append($0)
            return true
        }
        state.retranscribeHistoryEntry(recordingPath: oldPath)
        state.handleEvent(["type": "error", "message": "Synthetic unrelated error"])
        state.record()
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": "Late old words", "recording_path": oldPath,
                           "recording_created_at": ISO8601DateFormatter().string(from: oldDate)])
        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertTrue(pasted.isEmpty)
        state.handleEvent(["type": "transcription", "text": "Current synthetic words", "recording_path": newPath,
                           "recording_created_at": ISO8601DateFormatter().string(from: newDate)])
        XCTAssertEqual(pasted, ["Current synthetic words"])
        XCTAssertEqual(state.latestReusableTranscript, "Current synthetic words")
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [newPath, oldPath])
    }

    func testRecentsSaveTheChronologicalArchiveProjection() {
        var saved: [RecentTranscriptionEntry] = []
        var savedTexts: [String] = []
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { savedTexts = $0 },
            recentTranscriptionEntriesLoader: {
                [RecentTranscriptionEntry(text: "Existing words", recordingPath: self.oldPath, createdAt: self.oldDate)]
            }, recentTranscriptionEntriesSaver: { saved = $0 }
        )
        state.minimumTranscribingDisplayDuration = 0
        retranscribe(state, path: newPath, text: "Recovered words", date: newDate)
        XCTAssertEqual(savedTexts, ["Recovered words", "Existing words"])
        XCTAssertEqual(saved.first?.recordingPath, newPath)
        XCTAssertEqual(saved.first?.createdAt, newDate)
    }
}
