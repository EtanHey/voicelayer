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
}
