import AVFoundation
import Foundation

protocol AudioLevelMonitoringInputNode {
    func inputFormat() -> AVAudioFormat?
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
}

protocol AudioLevelMonitoringEngine {
    var monitoringInputNode: AudioLevelMonitoringInputNode { get }
    func prepare()
    func start() throws
    func stop()
}

private final class AVAudioLevelMonitoringEngine: AudioLevelMonitoringEngine {
    private let engine = AVAudioEngine()
    private lazy var inputNode = AVAudioLevelMonitoringInputNode(node: engine.inputNode)

    var monitoringInputNode: AudioLevelMonitoringInputNode {
        inputNode
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
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

final class AudioLevelMonitor {
    private let engine: AudioLevelMonitoringEngine
    private let onLevel: (Double?) -> Void
    private var inputNode: AudioLevelMonitoringInputNode?
    private var isPrepared = false
    private var isRunning = false

    init(
        engine: AudioLevelMonitoringEngine = AVAudioLevelMonitoringEngine(),
        onLevel: @escaping (Double?) -> Void
    ) {
        self.engine = engine
        self.onLevel = onLevel
    }

    func prepare() {
        guard !isPrepared else { return }
        inputNode = engine.monitoringInputNode
        _ = inputNode?.inputFormat()
        engine.prepare()
        isPrepared = true
    }

    func start() {
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
            DispatchQueue.main.async {
                self.onLevel(nil)
            }
            NSLog("[VoiceBar] AudioLevelMonitor failed to start: %@", String(describing: error))
        }
    }

    func stop() {
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

    deinit {
        // Ensure tap + engine are torn down even if caller forgets stop()
        if isRunning {
            inputNode?.removeTap()
            engine.stop()
        }
    }

    func restart() {
        stop()
        start()
    }

    static func normalizeAveragePower(_ averagePower: Float) -> Double {
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
