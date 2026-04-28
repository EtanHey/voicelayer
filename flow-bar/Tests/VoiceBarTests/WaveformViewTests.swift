@testable import VoiceBar
import XCTest

final class WaveformViewTests: XCTestCase {
    func testListeningModeUsesMinimumAmplitudeWhenAudioLevelIsNil() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { time in
            WaveformMetrics.normalizedLevel(
                mode: .listening,
                audioLevel: nil,
                time: time,
                index: 3,
                barCount: 7
            )
        }

        XCTAssertEqual(samples, Array(repeating: 0, count: samples.count))
    }

    func testListeningModeUsesMinimumAmplitudeWhenAudioLevelIsSilent() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { time in
            WaveformMetrics.normalizedLevel(
                mode: .listening,
                audioLevel: 0,
                time: time,
                index: 3,
                barCount: 7
            )
        }

        XCTAssertEqual(samples, Array(repeating: 0, count: samples.count))
    }

    func testListeningModeRespondsOnceRealAudioArrives() {
        let quiet = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: 0.39,
            time: 0.5,
            index: 3,
            barCount: 7
        )
        let louder = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: 0.8,
            time: 0.5,
            index: 3,
            barCount: 7
        )

        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(louder, quiet)
    }

    func testListeningModeNoiseGatesObservedSilentMicFloor() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { time in
            WaveformMetrics.normalizedLevel(
                mode: .listening,
                audioLevel: 0.375,
                time: time,
                index: 3,
                barCount: 7
            )
        }

        XCTAssertEqual(samples, Array(repeating: 0, count: samples.count))
    }

    func testListeningModeStillRespondsAboveSilenceGate() {
        let sample = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: 0.39,
            time: 0.5,
            index: 3,
            barCount: 7
        )

        XCTAssertGreaterThan(sample, 0)
    }
}
