@testable import VoiceBar
import XCTest

final class AudioLevelMonitorTests: XCTestCase {
    func testNormalizePowerClampsAndMapsIntoWaveformRange() {
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(-120), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(-10), 0.917, accuracy: 0.01)
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(10), 1, accuracy: 0.001)
    }
}
