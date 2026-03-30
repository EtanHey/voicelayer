import AVFoundation
import Foundation

final class AudioLevelMonitor {
    private let engine = AVAudioEngine()
    private let bus: AVAudioNodeBus = 0
    private let onLevel: (Double?) -> Void
    private var isRunning = false

    init(onLevel: @escaping (Double?) -> Void) {
        self.onLevel = onLevel
    }

    func start() {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: bus)

        inputNode.removeTap(onBus: bus)
        inputNode.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(from: buffer)
            DispatchQueue.main.async {
                self.onLevel(level)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: bus)
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

        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        isRunning = false
        DispatchQueue.main.async {
            self.onLevel(nil)
        }
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
