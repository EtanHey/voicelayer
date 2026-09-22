@testable import VoiceBarUI
import XCTest

final class DictationReceiptTests: XCTestCase {
    private let firstPath = "/tmp/voice-recordings/first/audio.wav"
    private let secondPath = "/tmp/voice-recordings/second/audio.wav"

    private func finalEvent(
        text: String = "A completed dictation",
        path: String? = "/tmp/voice-recordings/final/audio.wav",
        audioMilliseconds: Any = 1250,
        processingMilliseconds: Any = 375,
        partial: Bool = false
    ) -> [String: Any] {
        var event: [String: Any] = [
            "type": "transcription",
            "text": text,
            "partial": partial,
            "dictation_receipt": [
                "audio_duration_ms": audioMilliseconds,
                "processing_duration_ms": processingMilliseconds,
            ],
        ]
        if let path {
            event["recording_path"] = path
        }
        return event
    }

    private func state(
        entries: [RecentTranscriptionEntry] = [],
        saver: @escaping ([RecentTranscriptionEntry]) -> Void = { _ in }
    ) -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { entries },
            recentTranscriptionEntriesSaver: saver
        )
        state.minimumTranscribingDisplayDuration = 0
        return state
    }

    func testImmediateFinalEventStoresValidatedReceiptAndConvertsMilliseconds() throws {
        let state = state()

        state.handleEvent(finalEvent())

        let receipt = try XCTUnwrap(state.recentTranscriptionEntries.first?.dictationReceipt)
        XCTAssertEqual(receipt.audioDurationMilliseconds, 1250)
        XCTAssertEqual(receipt.processingDurationMilliseconds, 375)
        XCTAssertEqual(receipt.audioDuration, 1.25, accuracy: 0.0001)
        XCTAssertEqual(receipt.processingDuration, 0.375, accuracy: 0.0001)
    }

    func testReceiptRequiresFinalEventWithRecordingPath() {
        let state = state()

        state.handleEvent(finalEvent(text: "Partial", partial: true))
        XCTAssertTrue(state.recentTranscriptionEntries.isEmpty)

        state.handleEvent(finalEvent(text: "No archive", path: nil))
        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "No archive")
        XCTAssertNil(state.recentTranscriptionEntries.first?.dictationReceipt)
    }

    func testMalformedReceiptValuesStayAbsentWithoutDroppingTextOrPath() {
        let invalidPairs: [(Any, Any)] = [
            (true, 250),
            (1000, false),
            (-1, 250),
            (1000, -1),
            (Double.infinity, 250),
            (1000, Double.nan),
            (Double(Int.max), 250),
            (1000, Double(Int.max).nextUp),
        ]

        for (index, pair) in invalidPairs.enumerated() {
            let path = "/tmp/voice-recordings/invalid-\(index)/audio.wav"
            let state = state()
            state.handleEvent(finalEvent(
                text: "Preserved \(index)",
                path: path,
                audioMilliseconds: pair.0,
                processingMilliseconds: pair.1
            ))

            XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Preserved \(index)")
            XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, path)
            XCTAssertNil(state.recentTranscriptionEntries.first?.dictationReceipt)
        }
    }

    func testDeferredFinalCarriesItsReceipt() async throws {
        let state = state()
        state.minimumTranscribingDisplayDuration = 0.02
        state.handleEvent(["type": "state", "state": "transcribing"])

        state.handleEvent(finalEvent(audioMilliseconds: 2000, processingMilliseconds: 420))
        XCTAssertTrue(state.recentTranscriptionEntries.isEmpty)
        try await Task.sleep(for: .milliseconds(60))

        let receipt = try XCTUnwrap(state.recentTranscriptionEntries.first?.dictationReceipt)
        XCTAssertEqual(receipt.audioDurationMilliseconds, 2000)
        XCTAssertEqual(receipt.processingDurationMilliseconds, 420)
    }

    func testCancelledDeferredFinalDoesNotRetainReceiptOrEntry() async {
        let state = state()
        state.minimumTranscribingDisplayDuration = 0.02
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(finalEvent())

        state.cancel()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(state.recentTranscriptionEntries.isEmpty)
    }

    func testSameTextFromDifferentRecordingsKeepsReceiptsWithTheirPaths() {
        let state = state()
        state.handleEvent(finalEvent(
            text: "Same words",
            path: firstPath,
            audioMilliseconds: 1000,
            processingMilliseconds: 100
        ))
        state.handleEvent(finalEvent(
            text: "Same words",
            path: secondPath,
            audioMilliseconds: 2000,
            processingMilliseconds: 200
        ))

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [secondPath, firstPath])
        XCTAssertEqual(
            state.recentTranscriptionEntries.map { $0.dictationReceipt?.audioDurationMilliseconds },
            [2000, 1000]
        )
    }

    func testHistoryRetranscriptionPreservesOriginalReceiptAndRejectsReplacement() throws {
        let original = try XCTUnwrap(DictationReceipt(
            audioDurationMilliseconds: 1500,
            processingDurationMilliseconds: 300
        ))
        let state = state(entries: [
            RecentTranscriptionEntry(
                text: "Original transcript",
                recordingPath: firstPath,
                dictationReceipt: original
            ),
        ])
        var command: [String: Any]?
        state.sendCommand = { command = $0 }

        state.retranscribeHistoryEntry(recordingPath: firstPath)
        let id = try XCTUnwrap(command?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": id,
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(finalEvent(
            text: "Corrected transcript",
            path: firstPath,
            audioMilliseconds: 9999,
            processingMilliseconds: 8888
        ))

        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Corrected transcript")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.dictationReceipt, original)
    }

    func testLegacyJSONAndRetentionNormalizationRemainCompatible() throws {
        let legacy = Data(#"[{"text":" Legacy text ","recordingPath":" /tmp/legacy/audio.wav "}]"#.utf8)
        let decoded = try JSONDecoder().decode([RecentTranscriptionEntry].self, from: legacy)
        XCTAssertNil(decoded.first?.dictationReceipt)

        let malformed = Data(
            #"[{"text":"Kept text","dictationReceipt":{"audioDurationMilliseconds":-1,"processingDurationMilliseconds":250}}]"#
                .utf8
        )
        let malformedDecoded = try JSONDecoder().decode([RecentTranscriptionEntry].self, from: malformed)
        XCTAssertEqual(malformedDecoded.first?.text, "Kept text")
        XCTAssertNil(malformedDecoded.first?.dictationReceipt)

        let receipt = try XCTUnwrap(DictationReceipt(
            audioDurationMilliseconds: 3250,
            processingDurationMilliseconds: 625
        ))
        let roundTripData = try JSONEncoder().encode([
            RecentTranscriptionEntry(
                text: " Persisted text ",
                recordingPath: " /tmp/persisted/audio.wav ",
                dictationReceipt: receipt
            ),
        ])
        let roundTrip = try JSONDecoder().decode([RecentTranscriptionEntry].self, from: roundTripData)
        var saved: [RecentTranscriptionEntry] = []
        let state = state(entries: roundTrip, saver: { saved = $0 })

        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Persisted text")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, "/tmp/persisted/audio.wav")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.dictationReceipt, receipt)

        state.handleEvent(finalEvent(text: "New entry", path: secondPath))
        XCTAssertEqual(saved.last?.dictationReceipt?.audioDurationMilliseconds, 3250)
    }
}
