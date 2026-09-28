import AppKit
@testable import VoiceBarUI
import XCTest

/// Spec §3 ("Recent items show time + the first words") and R4 UI pass #13 need a time per recent
/// transcription; entries now carry `createdAt`, and one helper words it for every surface.
final class RecentTranscriptionTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC

    private func label(_ secondsAgo: TimeInterval) -> String? {
        VoiceBarRelativeTime.label(now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar)
    }

    func testRelativeTimesPerRow() {
        XCTAssertEqual(label(0), "Just now")
        XCTAssertEqual(label(59), "Just now")
        XCTAssertEqual(label(60), "1 min ago")
        XCTAssertEqual(label(125), "2 min ago")
        XCTAssertEqual(label(59 * 60), "59 min ago")
        XCTAssertEqual(label(60 * 60), "1 hr ago")
        XCTAssertEqual(label(5 * 3600), "5 hr ago")
        XCTAssertEqual(label(20 * 3600), "Yesterday")
        XCTAssertEqual(label(3 * 86400), "Sep 18")
        XCTAssertNil(VoiceBarRelativeTime.label(nil, now: now, calendar: calendar),
                     "an entry saved before times were recorded shows no time rather than a wrong one")
        XCTAssertEqual(label(-30), "Just now", "a clock that moved backwards never shows a future time")
    }

    func testEntriesSavedBeforeTimesStillLoad() throws {
        let legacy = #"[{"text":"older entry","recordingPath":"/tmp/a.wav"}]"#
        let decoded = try JSONDecoder().decode([RecentTranscriptionEntry].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.text, "older entry")
        XCTAssertNil(decoded.first?.createdAt)

        let dated = RecentTranscriptionEntry(text: "new", createdAt: now)
        let roundTrip = try JSONDecoder().decode(
            RecentTranscriptionEntry.self, from: JSONEncoder().encode(dated)
        )
        XCTAssertEqual(roundTrip.createdAt, now)
    }

    func testANewDictationIsStampedAndARetranscriptionKeepsTheOriginalTime() throws {
        var saved: [RecentTranscriptionEntry] = []
        let original = Date(timeIntervalSinceNow: -600)
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: {
                [RecentTranscriptionEntry(text: "first pass", recordingPath: "/tmp/r/audio.wav", createdAt: original)]
            },
            recentTranscriptionEntriesSaver: { saved = $0 }
        )
        state.minimumTranscribingDisplayDuration = 0

        state.handleEvent(["type": "transcription", "text": "A fresh dictation", "partial": false,
                           "recording_path": "/tmp/fresh/audio.wav"])
        let fresh = try XCTUnwrap(state.recentTranscriptionEntries.first { $0.text == "A fresh dictation" })
        let stamp = try XCTUnwrap(fresh.createdAt)
        XCTAssertLessThan(abs(stamp.timeIntervalSinceNow), 5)

        state.handleEvent(["type": "transcription", "text": "second pass", "partial": false,
                           "recording_path": "/tmp/r/audio.wav"])
        let retranscribed = try XCTUnwrap(state.recentTranscriptionEntries
            .first { $0.recordingPath == "/tmp/r/audio.wav" })
        XCTAssertEqual(retranscribed.text, "second pass")
        XCTAssertEqual(retranscribed.createdAt, original, "the row keeps the time it was dictated")
        XCTAssertEqual(saved.first { $0.recordingPath == "/tmp/r/audio.wav" }?.createdAt, original)
    }
}
