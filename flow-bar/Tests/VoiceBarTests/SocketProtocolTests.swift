@testable import VoiceBar
import VoiceBarUI
import XCTest

final class SocketProtocolTests: XCTestCase {
    func testParsesDecodedPlaybackAmplitudeFromSpeakingEvent() throws {
        let envelope = try XCTUnwrap(SocketPlaybackAmplitudeParser.parse(event: [
            "type": "state",
            "state": "speaking",
            "playback_amplitude": [
                "source": "decoded-rms",
                "sample_interval_ms": 50,
                "samples": [0, 0.4, 1.2, -0.2],
            ],
        ]))

        XCTAssertEqual(envelope.source, .decodedRMS)
        XCTAssertEqual(envelope.sampleIntervalMilliseconds, 50)
        XCTAssertEqual(envelope.samples, [0, 0.4, 1, 0])
    }

    func testParsesExplicitUnavailablePlaybackAmplitude() throws {
        let envelope = try XCTUnwrap(SocketPlaybackAmplitudeParser.parse(event: [
            "type": "state",
            "state": "speaking",
            "playback_amplitude": [
                "source": "unavailable",
                "sample_interval_ms": 50,
                "samples": [],
            ],
        ]))

        XCTAssertEqual(envelope.source, .unavailable)
        XCTAssertTrue(envelope.samples.isEmpty)
    }

    func testParsesPlaybackAmplitudeAfterRealJSONDeserialization() throws {
        let json = #"{"type":"state","state":"speaking","playback_amplitude":{"source":"decoded-rms","sample_interval_ms":50,"samples":[0,0.4,1]}}"#
        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let envelope = try XCTUnwrap(SocketPlaybackAmplitudeParser.parse(event: event))

        XCTAssertEqual(envelope.samples, [0, 0.4, 1])
    }

    func testRejectsMalformedPlaybackAmplitude() {
        let malformedPayloads: [[String: Any]] = [
            ["source": "decoded-rms", "sample_interval_ms": 0, "samples": [0.2]],
            ["source": "decoded-rms", "sample_interval_ms": 50, "samples": ["loud"]],
            ["source": "decoded-rms", "sample_interval_ms": 50, "samples": []],
            ["source": "unavailable", "sample_interval_ms": 50, "samples": [0]],
            ["source": "synthetic", "sample_interval_ms": 50, "samples": [0.2]],
        ]

        for payload in malformedPayloads {
            XCTAssertNil(SocketPlaybackAmplitudeParser.parse(event: [
                "type": "state",
                "state": "speaking",
                "playback_amplitude": payload,
            ]))
        }
    }

    func testIgnoresPlaybackAmplitudeOutsideSpeakingState() {
        XCTAssertNil(SocketPlaybackAmplitudeParser.parse(event: [
            "type": "state",
            "state": "recording",
            "playback_amplitude": [
                "source": "decoded-rms",
                "sample_interval_ms": 50,
                "samples": [0.4],
            ],
        ]))
    }
}
