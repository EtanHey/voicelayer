import AVFoundation
import Foundation

public struct AudioStreamBuffer {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    public var normalizedAveragePower: Double {
        guard rms > 0 else { return 0 }
        let averagePower = 20 * log10(rms)
        return AudioLevelMonitor.normalizeAveragePower(averagePower)
    }
}

public protocol AudioStreamable {
    func audioStream() -> AsyncThrowingStream<AudioStreamBuffer, Error>
}

public enum AudioStreamError: Error, Equatable {
    case invalidInputFormat
    case streamAlreadyActive
}

public final class CoreAudioInputStream: AudioStreamable {
    private let engine: AVAudioEngine
    private let bus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount
    private let lock = NSLock()
    private var isStreaming = false

    public init(engine: AVAudioEngine = AVAudioEngine(), bufferSize: AVAudioFrameCount = 1024) {
        self.engine = engine
        self.bufferSize = bufferSize
    }

    public func audioStream() -> AsyncThrowingStream<AudioStreamBuffer, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            guard !isStreaming else {
                lock.unlock()
                continuation.finish(throwing: AudioStreamError.streamAlreadyActive)
                return
            }
            isStreaming = true
            lock.unlock()

            func markStopped() {
                lock.lock()
                isStreaming = false
                lock.unlock()
            }

            let inputNode = engine.inputNode
            let format = inputNode.inputFormat(forBus: bus)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                markStopped()
                continuation.finish(throwing: AudioStreamError.invalidInputFormat)
                return
            }

            inputNode.removeTap(onBus: bus)
            inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: format) { buffer, _ in
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                continuation.yield(AudioStreamBuffer(samples: samples, sampleRate: format.sampleRate))
            }

            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: bus)
                markStopped()
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { [weak self, engine, inputNode, bus] _ in
                inputNode.removeTap(onBus: bus)
                engine.stop()
                self?.lock.lock()
                self?.isStreaming = false
                self?.lock.unlock()
            }
        }
    }
}
