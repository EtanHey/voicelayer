import AVFoundation
@testable import VoiceBarUI
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

    func testStopRemovesTapAndStopsEngine() {
        let engine = AudioLevelMonitorEngineSpy()
        let monitor = AudioLevelMonitor(engine: engine) { _ in }

        monitor.start()
        let removeTapCountAfterStart = engine.inputNode.removeTapCallCount
        XCTAssertEqual(engine.inputNode.installTapCallCount, 1)
        XCTAssertEqual(engine.startCallCount, 1)

        monitor.stop()
        // stop() adds one more removeTap call
        XCTAssertEqual(engine.inputNode.removeTapCallCount, removeTapCountAfterStart + 1)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testDeinitCleansUpRunningEngine() {
        let engine = AudioLevelMonitorEngineSpy()
        var monitor: AudioLevelMonitor? = AudioLevelMonitor(engine: engine) { _ in }
        monitor?.start()

        let removeTapCountAfterStart = engine.inputNode.removeTapCallCount
        XCTAssertEqual(engine.inputNode.installTapCallCount, 1)
        XCTAssertEqual(engine.startCallCount, 1)

        // Deallocate without calling stop()
        monitor = nil

        // deinit should have cleaned up
        XCTAssertEqual(engine.inputNode.removeTapCallCount, removeTapCountAfterStart + 1)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testDeinitReleasesPreparedInputEvenWhenNotRunning() {
        let engine = AudioLevelMonitorEngineSpy()
        var monitor: AudioLevelMonitor? = AudioLevelMonitor(engine: engine) { _ in }
        monitor?.prepare()

        monitor = nil

        XCTAssertEqual(engine.inputNode.removeTapCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testShutdownReleasesAPreparedButIdleInputAndAllowsFreshPreparation() {
        let engine = AudioLevelMonitorEngineSpy()
        let monitor = AudioLevelMonitor(engine: engine) { _ in }

        monitor.prepare()
        monitor.shutdown()
        monitor.prepare()

        XCTAssertEqual(engine.inputNode.removeTapCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(engine.inputNodeAccessCount, 2)
        XCTAssertEqual(engine.prepareCallCount, 2)
    }

    func testStartFailureRemovesTapAndStopsEngineDefensively() {
        let engine = AudioLevelMonitorEngineSpy()
        engine.shouldThrowOnStart = true
        let monitor = AudioLevelMonitor(engine: engine) { _ in }

        monitor.start()

        XCTAssertEqual(engine.inputNode.installTapCallCount, 1)
        XCTAssertEqual(engine.inputNode.removeTapCallCount, 2)
        XCTAssertEqual(engine.stopCallCount, 1)
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
    var shouldThrowOnStart = false

    var monitoringInputNode: AudioLevelMonitoringInputNode {
        inputNodeAccessCount += 1
        return inputNode
    }

    func prepare() {
        prepareCallCount += 1
    }

    func start() throws {
        startCallCount += 1
        if shouldThrowOnStart {
            throw NSError(domain: "AudioLevelMonitorEngineSpy", code: 1)
        }
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
