@testable import VoiceBarUI
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
            audioLevel: WaveformMetrics.listeningTargetLevel(from: 0.59),
            time: 0.5,
            index: 3,
            barCount: 7
        )
        let louder = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: WaveformMetrics.listeningTargetLevel(from: 0.8),
            time: 0.5,
            index: 3,
            barCount: 7
        )

        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(louder, quiet)
    }

    func testListeningModePreservesDynamicRangeAboveSilenceGate() {
        let justAboveGate = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: WaveformMetrics.listeningTargetLevel(from: WaveformMetrics.listeningSilenceFloor + 0.01),
            time: 0.5,
            index: 3,
            barCount: 7
        )
        let loudSpeech = WaveformMetrics.normalizedLevel(
            mode: .listening,
            audioLevel: WaveformMetrics.listeningTargetLevel(from: 0.9),
            time: 0.5,
            index: 3,
            barCount: 7
        )

        XCTAssertLessThan(justAboveGate, 0.2)
        XCTAssertGreaterThan(loudSpeech - justAboveGate, 0.35)
    }

    func testListeningModeNoiseGatesObservedSilentMicFloor() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.25).map { time in
            WaveformMetrics.normalizedLevel(
                mode: .listening,
                audioLevel: WaveformMetrics.listeningTargetLevel(from: 0.55),
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
            audioLevel: WaveformMetrics.listeningTargetLevel(from: 0.59),
            time: 0.5,
            index: 3,
            barCount: 7
        )

        XCTAssertGreaterThan(sample, 0)
    }

    func testListeningTargetLevelNoiseGatesQuietRoomTone() {
        XCTAssertEqual(WaveformMetrics.listeningTargetLevel(from: 0.55), 0)
        XCTAssertGreaterThan(WaveformMetrics.listeningTargetLevel(from: 0.59), 0)
    }

    func testProcessingModeIsSymmetricAroundCenter() {
        let time = 0.42
        let left = WaveformMetrics.normalizedLevel(
            mode: .processing,
            audioLevel: nil,
            time: time,
            index: 1,
            barCount: 7
        )
        let right = WaveformMetrics.normalizedLevel(
            mode: .processing,
            audioLevel: nil,
            time: time,
            index: 5,
            barCount: 7
        )

        XCTAssertEqual(left, right, accuracy: 0.0001)
    }

    func testProcessingModeAnimatesWithoutAudioInput() {
        let early = WaveformMetrics.normalizedLevel(
            mode: .processing,
            audioLevel: nil,
            time: 0.1,
            index: 3,
            barCount: 7
        )
        let later = WaveformMetrics.normalizedLevel(
            mode: .processing,
            audioLevel: nil,
            time: 0.6,
            index: 3,
            barCount: 7
        )

        XCTAssertNotEqual(early, later)
    }
}
