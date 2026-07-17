@testable import VoiceBarUI
import XCTest

final class PlaybackAmplitudeTests: XCTestCase {
    func testDecodedEnvelopeIndexesByElapsedPlaybackTime() {
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0, 0.4, 0.9]
        )

        XCTAssertEqual(envelope.level(elapsedMilliseconds: 0), 0)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 49), 0)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 75), 0.4, accuracy: 0.0001)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 149), 0.9, accuracy: 0.0001)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 150), 0)
    }

    func testEnvelopeReturnsFlatTruthOutsideValidTimeRange() {
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0.7]
        )

        XCTAssertEqual(envelope.level(elapsedMilliseconds: -1), 0)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 500), 0)
    }

    func testUnavailableEnvelopeNeverInventsMotion() {
        let envelope = PlaybackAmplitudeEnvelope(
            source: .unavailable,
            sampleIntervalMilliseconds: 50,
            samples: []
        )

        XCTAssertEqual(envelope.level(elapsedMilliseconds: 0), 0)
        XCTAssertEqual(envelope.level(elapsedMilliseconds: 500), 0)
    }
}
