@testable import VoiceBarUI
import XCTest

final class WaveformEnvelopeHistoryTests: XCTestCase {
    func testLiveWindowUsesTimeOffsetRealSamplesWithoutBellWeighting() {
        var history = WaveformEnvelopeHistory()
        for (index, level) in [0.1, 0.4, 0.2, 0.8, 0.3, 0.6, 0.5].enumerated() {
            history.append(level: level, atUptimeMilliseconds: index * 50)
        }

        XCTAssertEqual(history.liveWindow(barCount: 7), [0.1, 0.4, 0.2, 0.8, 0.3, 0.6, 0.5])
    }

    func testReplayStartsAtLastLiveWindowAndAdvancesAcrossRecordedSamples() {
        var history = WaveformEnvelopeHistory()
        for (index, level) in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8].enumerated() {
            history.append(level: level, atUptimeMilliseconds: index * 50)
        }

        XCTAssertEqual(
            history.replayWindow(elapsedMilliseconds: 0, barCount: 7),
            [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        )
        XCTAssertEqual(
            history.replayWindow(elapsedMilliseconds: 50, barCount: 7),
            [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.1]
        )
    }

    func testLatestRealSampleUpdatesImmediatelyWithoutAddingOnsetLatency() {
        var history = WaveformEnvelopeHistory()
        history.append(level: 0.1, atUptimeMilliseconds: 0)
        history.append(level: 0.9, atUptimeMilliseconds: 20)

        XCTAssertEqual(history.samples, [0.9])
        XCTAssertEqual(history.liveWindow(barCount: 3), [0, 0, 0.9])
    }

    func testIrregularEventsFillEveryCompletedFiftyMillisecondSlot() {
        var history = WaveformEnvelopeHistory()
        history.append(level: 0.1, atUptimeMilliseconds: 0)
        history.append(level: 0.4, atUptimeMilliseconds: 50)
        history.append(level: 0.9, atUptimeMilliseconds: 200)

        XCTAssertEqual(history.samples, [0.1, 0.4, 0.4, 0.4, 0.9])
    }

    func testShortReplayPreservesTheLiveWindowsLeadingSilenceSlots() {
        var history = WaveformEnvelopeHistory()
        history.append(level: 0.4, atUptimeMilliseconds: 0)
        history.append(level: 0.8, atUptimeMilliseconds: 50)

        XCTAssertEqual(
            history.replayWindow(elapsedMilliseconds: 0, barCount: 7),
            [0, 0, 0, 0, 0, 0.4, 0.8]
        )
        XCTAssertEqual(
            history.replayWindow(elapsedMilliseconds: 50, barCount: 7),
            [0, 0, 0, 0, 0.4, 0.8, 0]
        )
    }
}
