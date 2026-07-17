import Foundation

public struct WaveformEnvelopeHistory: Equatable {
    public static let sampleIntervalMilliseconds = 50
    public static let maximumSampleCount = 24000

    public private(set) var samples: [Double] = []
    private var lastSampleUptimeMilliseconds: Int?

    public init() {}

    public mutating func append(level: Double, atUptimeMilliseconds uptime: Int) {
        let realLevel = level.isFinite ? min(1, max(0, level)) : 0
        if let lastSampleUptimeMilliseconds, !samples.isEmpty {
            let elapsedMilliseconds = uptime - lastSampleUptimeMilliseconds
            if elapsedMilliseconds < Self.sampleIntervalMilliseconds {
                samples[samples.count - 1] = realLevel
                return
            }

            let completedIntervals = elapsedMilliseconds / Self.sampleIntervalMilliseconds
            let missingIntervalCount = min(
                max(0, completedIntervals - 1),
                Self.maximumSampleCount
            )
            if missingIntervalCount > 0, let previousLevel = samples.last {
                samples.append(
                    contentsOf: Array(repeating: previousLevel, count: missingIntervalCount)
                )
            }
            samples.append(realLevel)
            self.lastSampleUptimeMilliseconds = lastSampleUptimeMilliseconds
                + (completedIntervals * Self.sampleIntervalMilliseconds)
            trimToBound()
            return
        }

        samples.append(realLevel)
        lastSampleUptimeMilliseconds = uptime
        trimToBound()
    }

    private mutating func trimToBound() {
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }

    public func liveWindow(barCount: Int) -> [Double] {
        guard barCount > 0 else { return [] }
        let suffix = Array(samples.suffix(barCount))
        return Array(repeating: 0, count: max(0, barCount - suffix.count)) + suffix
    }

    public func replayWindow(elapsedMilliseconds: Int, barCount: Int) -> [Double]? {
        guard !samples.isEmpty, barCount > 0 else { return nil }
        let replaySamples = samples.count < barCount
            ? Array(repeating: 0, count: barCount - samples.count) + samples
            : samples
        let initialIndex = max(0, replaySamples.count - barCount)
        let replayOffset = max(0, elapsedMilliseconds) / Self.sampleIntervalMilliseconds
        return (0 ..< barCount).map { barIndex in
            replaySamples[(initialIndex + replayOffset + barIndex) % replaySamples.count]
        }
    }
}
