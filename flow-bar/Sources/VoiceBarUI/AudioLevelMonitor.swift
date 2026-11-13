import AVFoundation
import Foundation

public protocol AudioLevelMonitoringInputNode {
    func inputFormat() -> AVAudioFormat?
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
}

public protocol AudioLevelMonitoringEngine {
    var monitoringInputNode: AudioLevelMonitoringInputNode { get }
    func prepare()
    func start() throws
    func stop()
}

/// The real meter engine opens this Mac's microphone input, so it refuses to work inside a test process: a test
/// must inject a fake (`AudioLevelMonitor(engine:)`, `configureAudioLevelMonitoringForTesting`). Until 2026-11-13 a
/// test that forgot to opened the microphone on every suite run (#906). The refusal is loud: the default reporter
/// raises, which XCTest records as that test's failure.
enum RealMicrophoneMeterGuard {
    /// True only where XCTest itself is loaded or the process is a test runner (`xctest`, or SwiftPM's
    /// `swiftpm-testing-helper`, which runs Swift Testing suites and need not load XCTest). Deliberately NOT the
    /// `XCTestConfigurationFilePath` environment variable: a child process can inherit it, and an app launched
    /// from a test runner must keep its real meter (Codex review of #909, claim 3).
    static let runsInsideTests: Bool =
        NSClassFromString("XCTestCase") != nil
            || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)

    static let refusal =
        "AudioLevelMonitor: the real AVAudioEngine meter refuses to start inside a test process. Inject a fake engine."

    /// Test seam: what "inside a test process" means, and how a refusal is reported.
    static var isTestProcess: () -> Bool = { runsInsideTests }
    static var report: (String) -> Void = { reason in
        NSException(name: .internalInconsistencyException, reason: reason).raise()
    }
}

struct RealMicrophoneMeterRefused: Error {}

final class AVAudioLevelMonitoringEngine: AudioLevelMonitoringEngine {
    /// Built on first real use only, so a refused engine never touches the audio device.
    private(set) var didBuildEngine = false
    private lazy var engine: AVAudioEngine = {
        didBuildEngine = true
        return AVAudioEngine()
    }()
    private lazy var inputNode = AVAudioLevelMonitoringInputNode(node: engine.inputNode)
    private var didReportRefusal = false

    /// True inside a test process; reports the refusal once per engine.
    private var refuses: Bool {
        guard RealMicrophoneMeterGuard.isTestProcess() else { return false }
        if !didReportRefusal {
            didReportRefusal = true
            RealMicrophoneMeterGuard.report(RealMicrophoneMeterGuard.refusal)
        }
        return true
    }

    var monitoringInputNode: AudioLevelMonitoringInputNode {
        refuses ? RefusedAudioLevelMonitoringInputNode() : inputNode
    }

    func prepare() {
        guard !refuses else { return }
        engine.prepare()
    }

    func start() throws {
        guard !refuses else { throw RealMicrophoneMeterRefused() }
        try engine.start()
    }

    func stop() {
        guard didBuildEngine else { return }
        engine.stop()
    }
}

/// Stands in for the input node of a refused real engine: no format, no tap, no device.
private struct RefusedAudioLevelMonitoringInputNode: AudioLevelMonitoringInputNode {
    func inputFormat() -> AVAudioFormat? { nil }
    func installTap(
        bufferSize _: AVAudioFrameCount,
        format _: AVAudioFormat?,
        block _: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {}
    func removeTap() {}
}

private final class AVAudioLevelMonitoringInputNode: AudioLevelMonitoringInputNode {
    private let node: AVAudioInputNode
    private let bus: AVAudioNodeBus = 0

    init(node: AVAudioInputNode) {
        self.node = node
    }

    func inputFormat() -> AVAudioFormat? {
        node.inputFormat(forBus: bus)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        node.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
    }

    func removeTap() {
        node.removeTap(onBus: bus)
    }
}

public final class AudioLevelMonitor {
    private let engine: AudioLevelMonitoringEngine
    private let onLevel: (Double?) -> Void
    private var inputNode: AudioLevelMonitoringInputNode?
    private var isPrepared = false
    private var isRunning = false

    public init(
        engine: AudioLevelMonitoringEngine,
        onLevel: @escaping (Double?) -> Void
    ) {
        self.engine = engine
        self.onLevel = onLevel
    }

    public convenience init(onLevel: @escaping (Double?) -> Void) {
        self.init(engine: AVAudioLevelMonitoringEngine(), onLevel: onLevel)
    }

    public func prepare() {
        guard !isPrepared else { return }
        inputNode = engine.monitoringInputNode
        _ = inputNode?.inputFormat()
        engine.prepare()
        isPrepared = true
    }

    public func start() {
        guard !isRunning else { return }
        prepare()

        guard let inputNode else { return }
        let format = inputNode.inputFormat()

        inputNode.removeTap()
        inputNode.installTap(bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(from: buffer)
            DispatchQueue.main.async {
                self.onLevel(level)
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap()
            engine.stop()
            DispatchQueue.main.async {
                self.onLevel(nil)
            }
            NSLog("[VoiceBar] AudioLevelMonitor failed to start: %@", String(describing: error))
        }
    }

    public func stop() {
        guard isRunning else {
            DispatchQueue.main.async {
                self.onLevel(nil)
            }
            return
        }

        inputNode?.removeTap()
        engine.stop()
        isRunning = false
        DispatchQueue.main.async {
            self.onLevel(nil)
        }
    }

    /// Final teardown releases even a prepared-but-not-running input node.
    public func shutdown() {
        inputNode?.removeTap()
        engine.stop()
        inputNode = nil
        isRunning = false
        isPrepared = false
        DispatchQueue.main.async {
            self.onLevel(nil)
        }
    }

    deinit {
        if isRunning || isPrepared {
            inputNode?.removeTap()
            engine.stop()
        }
    }

    public func restart() {
        stop()
        start()
    }

    public static func normalizeAveragePower(_ averagePower: Float) -> Double {
        let clamped = max(-120, min(0, averagePower))
        return Double((clamped + 120) / 120)
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for index in 0 ..< frameLength {
            let sample = channelData[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        guard rms > 0 else { return 0 }
        let averagePower = 20 * log10(rms)
        return normalizeAveragePower(averagePower)
    }
}
