import AVFoundation
@testable import VoiceBarUI
import XCTest

final class AudioLevelMonitorTests: XCTestCase {
    /// #906 review (Codex P2): the real meter engine must never open the microphone from a test process.
    func testRealEngineRefusesInsideATestProcessAndSaysSo() {
        let savedReport = RealMicrophoneMeterGuard.report
        defer { RealMicrophoneMeterGuard.report = savedReport }
        var reports: [String] = []
        RealMicrophoneMeterGuard.report = { reports.append($0) }
        XCTAssertTrue(RealMicrophoneMeterGuard.runsInsideTests, "this process must be recognised as a test process")

        let engine = AVAudioLevelMonitoringEngine()
        var levels: [Double?] = []
        let delivered = expectation(description: "a refused start reports no level")
        delivered.assertForOverFulfill = false // stop() reports "no level" once more
        let monitor = AudioLevelMonitor(engine: engine) { levels.append($0); delivered.fulfill() }

        monitor.start()
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(reports, [RealMicrophoneMeterGuard.refusal], "one loud refusal per engine")
        XCTAssertFalse(engine.didBuildEngine, "a refused engine never builds AVAudioEngine")
        XCTAssertEqual(levels.count, 1)
        XCTAssertNil(levels.first ?? 1)
        XCTAssertThrowsError(try engine.start()) { XCTAssertTrue($0 is RealMicrophoneMeterRefused) }
        monitor.stop()
        XCTAssertFalse(engine.didBuildEngine)
    }

    /// The guard is a test-process rule only: outside one, the real engine takes its normal path.
    func testRealEngineIsNotRefusedOutsideATestProcess() {
        let savedProbe = RealMicrophoneMeterGuard.isTestProcess
        let savedReport = RealMicrophoneMeterGuard.report
        defer { RealMicrophoneMeterGuard.isTestProcess = savedProbe; RealMicrophoneMeterGuard.report = savedReport }
        var reports = 0
        RealMicrophoneMeterGuard.report = { _ in reports += 1 }
        RealMicrophoneMeterGuard.isTestProcess = { false }

        let engine = AVAudioLevelMonitoringEngine()
        engine.stop() // the only call that is safe without a device: it must not build the engine or refuse

        XCTAssertEqual(reports, 0)
        XCTAssertFalse(engine.didBuildEngine)
    }

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
