import AVFoundation
@testable import VoiceBar
import XCTest

final class AudioLevelMonitorTests: XCTestCase {
    func testPrepareWarmsEngineWithoutStartingIt() {
        let engine = AudioLevelMonitorEngineSpy()
        let monitor = AudioLevelMonitor(engine: engine) { _ in }

        monitor.prepare()

        XCTAssertEqual(engine.inputNodeAccessCount, 1)
        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.startCallCount, 0)
    }

    func testStartReusesPreparedEngineAndInstallsTapOnce() {
        let engine = AudioLevelMonitorEngineSpy()
        let monitor = AudioLevelMonitor(engine: engine) { _ in }

        monitor.prepare()
        monitor.start()

        XCTAssertEqual(engine.inputNodeAccessCount, 1)
        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.startCallCount, 1)
        XCTAssertEqual(engine.inputNode.installTapCallCount, 1)
    }

    func testNormalizePowerClampsAndMapsIntoWaveformRange() {
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(-120), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(-10), 0.917, accuracy: 0.01)
        XCTAssertEqual(AudioLevelMonitor.normalizeAveragePower(10), 1, accuracy: 0.001)
    }
}

private final class AudioLevelMonitorEngineSpy: AudioLevelMonitoringEngine {
    let inputNode = AudioLevelMonitorInputNodeSpy()
    private(set) var inputNodeAccessCount = 0
    private(set) var prepareCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var monitoringInputNode: AudioLevelMonitoringInputNode {
        inputNodeAccessCount += 1
        return inputNode
    }

    func prepare() {
        prepareCallCount += 1
    }

    func start() throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class AudioLevelMonitorInputNodeSpy: AudioLevelMonitoringInputNode {
    private(set) var installTapCallCount = 0
    private(set) var removeTapCallCount = 0

    func inputFormat() -> AVAudioFormat? {
        nil
    }

    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat?,
        block _: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        installTapCallCount += 1
    }

    func removeTap() {
        removeTapCallCount += 1
    }
}
