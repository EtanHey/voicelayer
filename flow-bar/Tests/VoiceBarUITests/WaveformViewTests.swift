@testable import VoiceBarUI
import XCTest

final class WaveformViewTests: XCTestCase {
    func testMissingAndSilentAmplitudeUseMinimumLevel() {
        XCTAssertEqual(
            WaveformMetrics.normalizedLevel(audioLevel: nil, index: 3, barCount: 7),
            0
        )
        XCTAssertEqual(
            WaveformMetrics.normalizedLevel(audioLevel: 0, index: 3, barCount: 7),
            0
        )
    }

    func testLouderAmplitudeProducesTallerBars() {
        for index in 0 ..< 7 {
            let quiet = WaveformMetrics.normalizedLevel(
                audioLevel: 0.2,
                index: index,
                barCount: 7
            )
            let loud = WaveformMetrics.normalizedLevel(
                audioLevel: 0.8,
                index: index,
                barCount: 7
            )

            XCTAssertGreaterThan(loud, quiet, "bar \(index) must preserve amplitude ordering")
        }
    }

    func testEveryBarIsMonotonicAcrossAmplitudeRange() {
        for index in 0 ..< 7 {
            let levels = [0.0, 0.1, 0.4, 0.8, 1.0].map { amplitude in
                WaveformMetrics.normalizedLevel(
                    audioLevel: amplitude,
                    index: index,
                    barCount: 7
                )
            }

            for pair in zip(levels, levels.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    pair.0,
                    pair.1,
                    "bar \(index) must not shrink as real amplitude rises"
                )
            }
        }
    }

    func testIdenticalAmplitudeProducesIdenticalGeometry() {
        let first = (0 ..< 7).map { index in
            WaveformMetrics.normalizedLevel(audioLevel: 0.63, index: index, barCount: 7)
        }
        let second = (0 ..< 7).map { index in
            WaveformMetrics.normalizedLevel(audioLevel: 0.63, index: index, barCount: 7)
        }

        XCTAssertEqual(first, second)
    }

    func testCenterWeightingIsStaticAndSymmetric() {
        let levels = (0 ..< 7).map { index in
            WaveformMetrics.normalizedLevel(audioLevel: 0.5, index: index, barCount: 7)
        }

        XCTAssertEqual(levels[0], levels[6], accuracy: 0.0001)
        XCTAssertEqual(levels[1], levels[5], accuracy: 0.0001)
        XCTAssertEqual(levels[2], levels[4], accuracy: 0.0001)
        XCTAssertGreaterThan(levels[3], levels[0])
    }

    func testTimeOffsetLevelsPreserveIndependentRealShapeAndPeakPosition() {
        let realSamples = [0.7, 0.2, 0.6, 0.1, 0.3, 0.9, 0.4]

        XCTAssertEqual(
            WaveformMetrics.normalizedLevels(audioLevels: realSamples, barCount: 7),
            realSamples
        )
    }

    func testRecordingHistoryUsesEveryDistinctSliceWithNewestAtCenter() {
        let realSamples = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let levels = WaveformMetrics.centerOutLevels(
            audioLevels: realSamples,
            barCount: 7
        )
        let sourceLevelByBar = [0.2, 0.4, 0.6, 0.7, 0.5, 0.3, 0.1]
        let expected = sourceLevelByBar.enumerated().map { index, level in
            WaveformMetrics.normalizedLevel(
                audioLevel: level,
                index: index,
                barCount: 7
            )
        }

        XCTAssertEqual(levels.count, expected.count)
        for (actual, expectedLevel) in zip(levels, expected) {
            XCTAssertEqual(actual, expectedLevel, accuracy: 0.0001)
        }
    }

    func testRecordingHistoryRadiatesCenterOutWithoutChronologicalTravel() {
        let expectedBarBySampleAge = [3, 2, 4, 1, 5, 0, 6]
        let center = 3

        let actualBarBySampleAge = (0 ..< 7).map { age in
            var samples = Array(repeating: 0.0, count: 7)
            samples[6 - age] = 1
            let levels = WaveformMetrics.centerOutLevels(
                audioLevels: samples,
                barCount: 7
            )
            return levels.enumerated().max(by: { $0.element < $1.element })?.offset
        }

        XCTAssertEqual(actualBarBySampleAge, expectedBarBySampleAge.map(Optional.some))
        XCTAssertEqual(
            actualBarBySampleAge.compactMap { $0 }.map { abs($0 - center) },
            [0, 1, 1, 2, 2, 3, 3]
        )
    }

    func testRecordingHistoryKeepsTrueSilenceExactlyFlat() {
        XCTAssertEqual(
            WaveformMetrics.centerOutLevels(
                audioLevels: Array(repeating: 0, count: 7),
                barCount: 7
            ),
            Array(repeating: 0, count: 7)
        )
    }

    func testReactiveWindowUsesOrganicCenterOutVariationFromCurrentMagnitude() {
        let levels = WaveformMetrics.organicLevels(
            audioLevels: [0.9, 0.1, 0.8, 0.2, 0.7, 0.3, 0.6],
            time: 0.42,
            barCount: 7
        )

        let mirroredPairs = zip(levels.prefix(3), levels.suffix(3).reversed())
        XCTAssertTrue(mirroredPairs.contains { pair in
            abs(pair.0 - pair.1) > 0.01
        })

        let averages = (0 ..< 7).map { index in
            let samples = stride(from: 0.0, through: 4.0, by: 0.05).map { time in
                WaveformMetrics.organicLevels(
                    audioLevels: [0.6],
                    time: time,
                    barCount: 7
                )[index]
            }
            return samples.reduce(0, +) / Double(samples.count)
        }
        XCTAssertGreaterThan(averages[3], averages[0])
        XCTAssertGreaterThan(averages[3], averages[6])
    }

    func testReactiveWindowDoesNotTravelWhenOnlyHistoryChanges() {
        let first = WaveformMetrics.organicLevels(
            audioLevels: [0.9, 0.1, 0.8, 0.2, 0.7, 0.3, 0.6],
            time: 0.42,
            barCount: 7
        )
        let shifted = WaveformMetrics.organicLevels(
            audioLevels: [0.0, 0.9, 0.1, 0.8, 0.2, 0.7, 0.6],
            time: 0.42,
            barCount: 7
        )

        XCTAssertEqual(first, shifted)

        let attacks = (0 ..< 7).map { _ in
            WaveformMetrics.reactiveTransitionDuration(from: 0, to: 0.8)
        }
        XCTAssertEqual(Set(attacks).count, 1)
    }

    func testReactiveWindowUsesHardFlatFloorForSilentCurrentSample() {
        for time in [0.0, 0.42, 1.0] {
            let levels = WaveformMetrics.organicLevels(
                audioLevels: [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0],
                time: time,
                barCount: 7
            )

            XCTAssertEqual(levels, Array(repeating: 0, count: 7))
        }
    }

    func testReactiveRendererMeetsAttackAndDynamicRangeFloor() {
        XCTAssertEqual(
            WaveformMetrics.reactiveTransitionDuration(from: 0, to: 1),
            0.10,
            accuracy: 0.0001
        )

        let floorHeight = 3.0
        let peakLevel = stride(from: 0.0, through: 4.0, by: 0.01).flatMap { time in
            WaveformMetrics.organicLevels(audioLevels: [1], time: time, barCount: 7)
        }.max() ?? 0
        let peakHeight = floorHeight + (24 - floorHeight) * peakLevel

        XCTAssertGreaterThanOrEqual(peakHeight / floorHeight, 4.8)
    }

    func testProcessingMotionPulsesInPhaseWithoutLateralTravel() {
        let sampledTimes = stride(from: 0.0, through: 2.0, by: 0.05)
        let sampledLevels = sampledTimes.map {
            WaveformMetrics.processingLevels(time: $0, barCount: 7)
        }

        for levels in sampledLevels {
            XCTAssertEqual(levels[0], levels[6], accuracy: 0.0001)
            XCTAssertEqual(levels[1], levels[5], accuracy: 0.0001)
            XCTAssertEqual(levels[2], levels[4], accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(levels[3], levels[0])
        }

        for (current, next) in zip(sampledLevels, sampledLevels.dropFirst()) {
            let centerDelta = next[3] - current[3]
            for index in 0 ..< 7 {
                let barDelta = next[index] - current[index]
                XCTAssertGreaterThanOrEqual(
                    centerDelta * barDelta,
                    -0.000_001,
                    "processing bar \(index) must pulse in phase with the center"
                )
            }
        }
        XCTAssertNotEqual(sampledLevels.first, sampledLevels.last)
    }

    func testAmplitudeIsClampedBeforeHeightMapping() {
        XCTAssertEqual(
            WaveformMetrics.normalizedLevel(audioLevel: -0.5, index: 3, barCount: 7),
            0
        )
        XCTAssertEqual(
            WaveformMetrics.normalizedLevel(audioLevel: 1.5, index: 3, barCount: 7),
            WaveformMetrics.normalizedLevel(audioLevel: 1, index: 3, barCount: 7)
        )
    }

    func testRecordingSourceMapsObservedRoomToneToSilence() {
        let roomTone = AudioLevelMonitor.normalizeAveragePower(-50)

        XCTAssertEqual(WaveformMetrics.recordingLevel(from: nil), 0)
        XCTAssertEqual(WaveformMetrics.recordingLevel(from: roomTone), 0)
        XCTAssertGreaterThan(
            WaveformMetrics.recordingLevel(from: AudioLevelMonitor.normalizeAveragePower(-20)),
            0
        )
    }

    func testRecordingSourcePreservesOrderingAboveFixedSilenceFloor() {
        let quiet = WaveformMetrics.recordingLevel(
            from: AudioLevelMonitor.normalizeAveragePower(-40)
        )
        let loud = WaveformMetrics.recordingLevel(
            from: AudioLevelMonitor.normalizeAveragePower(-10)
        )

        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(loud, quiet)
    }

    func testRecordingTargetsUseStaggeredAttackAndNaturalRelease() {
        let attacks = (0 ..< 7).map { index in
            WaveformMetrics.transitionDuration(
                from: 0.2,
                to: 0.8,
                index: index,
                barCount: 7
            )
        }
        let releases = (0 ..< 7).map { index in
            WaveformMetrics.transitionDuration(
                from: 0.8,
                to: 0.2,
                index: index,
                barCount: 7
            )
        }

        XCTAssertTrue(attacks.allSatisfy { (0.10 ... 0.15).contains($0) })
        XCTAssertGreaterThan(Set(attacks).count, 1)
        XCTAssertGreaterThanOrEqual(releases.min() ?? 0, 0.18)
        XCTAssertEqual(releases.max() ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertGreaterThan(Set(releases).count, 1)
    }
}
