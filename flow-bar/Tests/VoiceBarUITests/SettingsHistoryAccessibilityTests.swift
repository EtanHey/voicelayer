@testable import VoiceBarUI
import XCTest

/// H1-d (UI pass #7, #10): one concise VoiceOver label per Dictations row, and History actions that are
/// hidden when they can never apply or say why when they are blocked for now.
final class SettingsHistoryAccessibilityTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private let english = Locale(identifier: "en_US")

    // MARK: - #7 row label

    /// UI pass #7: a 2:15 row's label was the full transcript repeated 4–5 times (~5 × 2,000 characters).
    func testALongRowReadsItsOpeningOnceWithTimeDurationAndEffort() {
        let transcript = String(repeating: "History playback finally has a scrub bar I can drag. ", count: 40)
        let entry = entry(transcript: transcript, durationMs: 135_000, effort: .accurate)

        let label = SettingsHistoryAccessibility.rowLabel(entry, locale: english, timeZone: utc)

        XCTAssertEqual(
            label,
            "History playback finally has a scrub bar I can drag. History playback finally…, "
                + "Sep 25, 2026 at 9:30 AM, 2 minutes 15 seconds, Accurate"
        )
        XCTAssertLessThan(label.count, 160)
    }

    func testAShortRowIsNotTruncatedAndOmitsWhatIsUnknown() {
        let entry = entry(transcript: "Ship it.", durationMs: nil, effort: nil)

        XCTAssertEqual(
            SettingsHistoryAccessibility.rowLabel(entry, locale: english, timeZone: utc),
            "Ship it., Sep 25, 2026 at 9:30 AM"
        )
    }

    func testARowWithoutATranscriptSaysSo() {
        let entry = entry(transcript: "  ", durationMs: 1000, effort: .fast)

        XCTAssertEqual(
            SettingsHistoryAccessibility.rowLabel(entry, locale: english, timeZone: utc),
            "No transcript stored, Sep 25, 2026 at 9:30 AM, 1 second, Fast"
        )
    }

    func testTheOpeningCutsAtAWordBoundary() {
        XCTAssertEqual(SettingsHistoryAccessibility.opening("one two three", limit: 9), "one two…")
        XCTAssertEqual(SettingsHistoryAccessibility.opening("  short  ", limit: 80), "short")
        XCTAssertEqual(SettingsHistoryAccessibility.opening(String(repeating: "x", count: 100), limit: 10),
                       String(repeating: "x", count: 10) + "…")
    }

    /// The rows must be one element each; the per-child labels were what repeated the transcript.
    func testDictationsRowsAreOneAccessibilityElement() throws {
        let source = try settingsViewSource()
        let row = try XCTUnwrap(source.range(of: "private func recordingHistoryListRow"))
        let body = String(source[row.lowerBound...].prefix(2000))

        XCTAssertTrue(body.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(body.contains("SettingsHistoryAccessibility.rowLabel(entry)"))
    }

    // MARK: - #10 unavailable actions

    func testActionsThatCanNeverApplyAreHidden() {
        let idle = SettingsHistoryActionEnablement(isRetranscribing: false, isRecording: false, isTranscribing: false)
        let noText = part(text: nil, audio: true)
        let noAudio = part(text: "hello", audio: false)

        XCTAssertEqual(idle.availability(.copy, for: noText), .hidden)
        XCTAssertEqual(idle.availability(.paste, for: noText), .hidden)
        XCTAssertEqual(idle.availability(.play, for: noAudio), .hidden)
        XCTAssertEqual(idle.availability(.finder, for: noAudio), .hidden)
        XCTAssertEqual(idle.availability(.copy, for: noAudio), .available)
    }

    func testActionsBlockedForNowSayWhy() {
        let clip = part(text: "hello", audio: true)
        let recording = SettingsHistoryActionEnablement(
            isRetranscribing: false,
            isRecording: true,
            isTranscribing: false
        )
        let transcribing = SettingsHistoryActionEnablement(
            isRetranscribing: false, isRecording: false, isTranscribing: true
        )
        let retranscribing = SettingsHistoryActionEnablement(
            isRetranscribing: true, isRecording: false, isTranscribing: false
        )

        XCTAssertEqual(recording.availability(.play, for: clip), .unavailable("Unavailable while recording"))
        XCTAssertEqual(recording.availability(.retranscribe, for: clip), .unavailable("Unavailable while recording"))
        XCTAssertEqual(transcribing.availability(.play, for: clip), .unavailable("Unavailable while transcribing"))
        XCTAssertEqual(retranscribing.availability(.retranscribe, for: clip),
                       .unavailable("Another re-transcription is running"))
        XCTAssertEqual(retranscribing.availability(.copy, for: clip),
                       .unavailable("Wait for the re-transcription to finish"))
        XCTAssertEqual(recording.availability(.copy, for: clip), .available)
    }

    /// The old Bool stays the single source of truth for enabling a button.
    func testAvailabilityAgreesWithIsEnabled() {
        for flags in [(false, false, false), (true, false, false), (false, true, false), (false, false, true)] {
            let enablement = SettingsHistoryActionEnablement(
                isRetranscribing: flags.0, isRecording: flags.1, isTranscribing: flags.2
            )
            for part in [part(text: nil, audio: true), part(text: "hi", audio: false), part(text: "hi", audio: true)] {
                for action in part.actions {
                    XCTAssertEqual(
                        enablement.availability(action, for: part) == .available,
                        enablement.isEnabled(action, for: part),
                        "\(action) \(flags)"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func entry(transcript: String, durationMs: Int?,
                       effort: VoiceBarPerformanceEffort?) -> SettingsHistoryEntry {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = utc
        components.year = 2026
        components.month = 9
        components.day = 25
        components.hour = 9
        components.minute = 30
        return SettingsHistoryEntry(
            id: "/tmp/a11y/audio.wav",
            dayKey: "2026-09-25",
            recordingID: "a11y",
            createdAt: components.date ?? Date(timeIntervalSince1970: 0),
            transcript: transcript,
            audioPath: URL(fileURLWithPath: "/tmp/a11y/audio.wav"),
            durationMs: durationMs,
            performanceEffort: effort
        )
    }

    private func part(text: String?, audio: Bool) -> SettingsHistoryMediaPart {
        SettingsHistoryMediaPart(
            role: .recording,
            displayText: text ?? "No transcript stored",
            isPlaceholder: text == nil,
            actionableText: text,
            audioPath: audio ? URL(fileURLWithPath: "/tmp/a11y/audio.wav") : nil,
            durationLabel: nil,
            transcribedDurationLabel: nil
        )
    }

    private func settingsViewSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
    }
}
