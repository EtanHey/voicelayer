import Foundation

public enum PlaybackAmplitudeSource: String, Equatable {
    case decodedRMS = "decoded-rms"
    case unavailable
}

public struct PlaybackAmplitudeEnvelope: Equatable {
    public static let maximumSampleCount = 1000

    public let source: PlaybackAmplitudeSource
    public let sampleIntervalMilliseconds: Int
    public let samples: [Double]

    public init(
        source: PlaybackAmplitudeSource,
        sampleIntervalMilliseconds: Int,
        samples: [Double]
    ) {
        self.source = source
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        self.samples = samples.map { min(1, max(0, $0)) }
    }

    public func level(elapsedMilliseconds: Int) -> Double {
        guard source == .decodedRMS,
              sampleIntervalMilliseconds > 0,
              elapsedMilliseconds >= 0
        else { return 0 }

        let position = Double(elapsedMilliseconds) / Double(sampleIntervalMilliseconds)
        let lowerIndex = Int(position.rounded(.down))
        guard samples.indices.contains(lowerIndex) else { return 0 }
        let upperIndex = lowerIndex + 1
        guard samples.indices.contains(upperIndex) else { return samples[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
    }
}
