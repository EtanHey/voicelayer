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

    func testProcessingMotionIsAnimatedSymmetricallyWithoutLateralTravel() {
        let early = WaveformMetrics.processingLevels(time: 0.1, barCount: 7)
        let later = WaveformMetrics.processingLevels(time: 0.6, barCount: 7)

        for levels in [early, later] {
            XCTAssertEqual(levels[0], levels[6], accuracy: 0.0001)
            XCTAssertEqual(levels[1], levels[5], accuracy: 0.0001)
            XCTAssertEqual(levels[2], levels[4], accuracy: 0.0001)
        }
        XCTAssertNotEqual(early, later)
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

    func testLiveTargetsUseGradedPerBarAttackAndSettleWithoutHolding() {
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

        XCTAssertTrue(attacks.allSatisfy { (0.10 ... 0.20).contains($0) })
        XCTAssertGreaterThan(Set(attacks).count, 1)
        XCTAssertGreaterThanOrEqual(releases.min() ?? 0, 0.18)
        XCTAssertLessThanOrEqual(releases.max() ?? 0, 0.30)
        XCTAssertGreaterThan(Set(releases).count, 1)
    }
}
