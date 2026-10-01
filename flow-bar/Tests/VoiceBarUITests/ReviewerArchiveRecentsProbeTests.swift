@testable import VoiceBarUI
import XCTest

final class ReviewerArchiveRecentsProbeTests: XCTestCase {
    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private func makeState(_ entries: [RecentTranscriptionEntry]) -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { entries }, recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0
        state.frontmostAppProvider = { nil }
        return state
    }

    // #186: an OLD recording re-transcribed from History must not take over Paste Last.
    func testOldHistoryRecoveryWithUndatedLegacyHeadDoesNotBecomeLatest() {
        let state = makeState([RecentTranscriptionEntry(text: "Legacy newest synthetic words")])
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        state.retranscribeHistoryEntry(recordingPath: "/tmp/synthetic-old3d/audio.wav")
        state.handleEvent(["type": "transcription", "text": "Three day old synthetic words",
                           "recording_path": "/tmp/synthetic-old3d/audio.wav",
                           "recording_created_at": iso(threeDaysAgo)])
        XCTAssertEqual(state.latestReusableTranscript, "Legacy newest synthetic words")
    }

    func testLiveFinalThenHistoryRetranscribeOfSamePathKeepsOneEntry() {
        let state = makeState([])
        let path = "/tmp/synthetic-race/audio.wav"
        let created = Date().addingTimeInterval(-60)
        state.handleEvent(["type": "transcription", "text": "First synthetic decode",
                           "recording_path": path, "recording_created_at": iso(created)])
        state.retranscribeHistoryEntry(recordingPath: path)
        state.handleEvent(["type": "transcription", "text": "Second synthetic decode",
                           "recording_path": path, "recording_created_at": iso(created)])
        XCTAssertEqual(state.recentTranscriptionEntries.filter { $0.recordingPath == path }.count, 1)
        XCTAssertEqual(state.latestReusableTranscript, "Second synthetic decode")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.createdAt.map { Int($0.timeIntervalSince1970) },
                       Int(created.timeIntervalSince1970))
    }
}
