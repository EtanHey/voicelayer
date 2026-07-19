@testable import VoiceBarUI
import XCTest

final class WaveformViewTests: XCTestCase {
    func testAudioDrivenFormulaMatchesM1GoldForEveryBar() {
        for level in [0.1, 0.43, 0.8, 1.0] {
            for time in [0.0, 0.42, 1.7] {
                let actual = WaveformMetrics.audioDrivenLevels(
                    level: level,
                    time: time,
                    barCount: 7,
                    isListening: false
                )

                for index in 0 ..< 7 {
                    XCTAssertEqual(
                        actual[index],
                        m1GoldLevel(level: level, time: time, index: index, barCount: 7),
                        accuracy: 0.000_000_1,
                        "bar \(index), level \(level), time \(time) must equal 5beaf34"
                    )
                }
            }
        }
    }

    func testListeningUsesM1GoldDampingBeforeTheFormula() {
        let level = 0.72
        let time = 0.63
        let actual = WaveformMetrics.audioDrivenLevels(
            level: level,
            time: time,
            barCount: 7,
            isListening: true
        )

        for index in 0 ..< 7 {
            XCTAssertEqual(
                actual[index],
                m1GoldLevel(
                    level: level * 0.7,
                    time: time,
                    index: index,
                    barCount: 7
                ),
                accuracy: 0.000_000_1
            )
        }
    }

    func testSharedEnvelopeUsesM1GoldAttackAndRelease() {
        XCTAssertEqual(WaveformMetrics.envelopeAttackDuration, 0.06, accuracy: 0.0001)
        XCTAssertEqual(WaveformMetrics.envelopeReleaseDuration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(WaveformMetrics.listeningDamping, 0.7, accuracy: 0.0001)
        XCTAssertEqual(
            WaveformMetrics.envelopeTransitionDuration(from: 0.2, to: 0.8),
            0.06,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WaveformMetrics.envelopeTransitionDuration(from: 0.8, to: 0.2),
            0.40,
            accuracy: 0.0001
        )
    }

    func testTruthfulSilenceIsExactlyFlatDespiteGoldShimmer() {
        for level in [nil, 0] as [Double?] {
            for time in [0.0, 0.42, 1.0] {
                XCTAssertEqual(
                    WaveformMetrics.audioDrivenLevels(
                        level: level,
                        time: time,
                        barCount: 7,
                        isListening: false
                    ),
                    Array(repeating: 0, count: 7)
                )
            }
        }
    }

    func testGoldenRatioShimmerIsPerBarAndNotAChronologicalSweep() {
        let first = WaveformMetrics.audioDrivenLevels(
            level: 0.6,
            time: 0.42,
            barCount: 7,
            isListening: false
        )
        let sameCurrentMagnitude = WaveformMetrics.audioDrivenLevels(
            level: 0.6,
            time: 0.42,
            barCount: 7,
            isListening: false
        )

        XCTAssertEqual(first, sameCurrentMagnitude)
        XCTAssertTrue(zip(first.prefix(3), first.suffix(3).reversed()).contains { pair in
            abs(pair.0 - pair.1) > 0.01
        })

        let averages = (0 ..< 7).map { index in
            let samples = stride(from: 0.0, through: 4.0, by: 0.05).map { time in
                WaveformMetrics.audioDrivenLevels(
                    level: 0.6,
                    time: time,
                    barCount: 7,
                    isListening: false
                )[index]
            }
            return samples.reduce(0, +) / Double(samples.count)
        }
        XCTAssertGreaterThan(averages[3], averages[0])
        XCTAssertGreaterThan(averages[3], averages[6])
    }

    func testProcessingFormulaMatchesM1Gold() {
        for time in [0.0, 0.42, 1.7] {
            let actual = WaveformMetrics.processingLevels(time: time, barCount: 7)
            for index in 0 ..< 7 {
                XCTAssertEqual(
                    actual[index],
                    m1GoldProcessingLevel(time: time, index: index, barCount: 7),
                    accuracy: 0.000_000_1
                )
            }
        }
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

    func testBarViewFeedsCurrentTruthSourcesIntoOneGoldFormula() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("currentLevel: { state.recordingWaveformLevel }"))
        XCTAssertTrue(source.contains("isListening: !state.speechDetected"))
        XCTAssertEqual(source.components(separatedBy: "state.playbackAudioLevel()").count - 1, 1)
        XCTAssertFalse(source.contains("recordingWaveformLevels"))
        XCTAssertFalse(source.contains("playbackWaveformLevels"))
        XCTAssertFalse(source.contains("centerOutHistory"))
    }

    func testTranscribingKeepsOneGoldWaveformInTheRecordingWingAndMorphsTheIndicator() throws {
        let source = try barViewSource()
        let leadingCompactStatusBranch = source
            .components(separatedBy: "case .compactStatus:")
            .dropFirst()
            .first?
            .components(separatedBy: "case .teleprompter:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingBranch = source
            .components(separatedBy: "private var notchTrailingContent")
            .dropFirst()
            .first?
            .components(separatedBy: "private var notchCompactStatusContent")
            .first

        XCTAssertTrue(leadingCompactStatusBranch?.contains("if state.mode == .transcribing") == true)
        XCTAssertTrue(leadingCompactStatusBranch?.contains("ProcessingSpinner()") == true)
        XCTAssertFalse(leadingCompactStatusBranch?.contains("WaveformView(") == true)
        XCTAssertTrue(trailingBranch?.contains("notchStableWaveform") == true)
        XCTAssertTrue(source.contains("private var notchStableWaveform"))
        XCTAssertTrue(source.contains("WaveformView(processingColor:"))
    }

    private func m1GoldLevel(
        level: Double,
        time: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let phi = 1.618033988749895
        let phaseOffset = Double(index) * phi
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let centerWeight = 1 - distance * 0.35
        let fast = sin(time * 7 + phaseOffset * 2.5) * 0.08
        let jitter = sin(time * 12 + phaseOffset * 6) * 0.05
        let motionScale = 0.4 + level * 0.6
        let base = 0.04 + level * 0.12
        let envelope = pow(level, 0.9) * centerWeight
        return max(0, min(1, base + envelope * 0.82 + (fast + jitter) * motionScale))
    }

    private func m1GoldProcessingLevel(
        time: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let center = Double(barCount - 1) / 2
        let distanceFromCenter = abs(Double(index) - center)
        let normalizedDistance = center == 0 ? 0 : distanceFromCenter / center
        let inwardOutward = sin(time * 4.8 - normalizedDistance * .pi) * 0.5 + 0.5
        let centerPulse = sin(time * 2.4) * 0.5 + 0.5
        let centerWeight = 1 - normalizedDistance * 0.35
        return max(0, min(1, 0.12 + inwardOutward * 0.38 + centerPulse * 0.16 * centerWeight))
    }

    private func barViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let barViewURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("BarView.swift")
        return try String(contentsOf: barViewURL, encoding: .utf8)
    }
}
