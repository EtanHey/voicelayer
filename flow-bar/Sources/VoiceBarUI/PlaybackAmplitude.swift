import Foundation

public enum PlaybackAmplitudeSource: String, Equatable {
    case decodedRMS = "decoded-rms"
    case unavailable
}

public struct PlaybackAmplitudeEnvelope: Equatable {
    public static let maximumSampleCount = 24000

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

        let index = elapsedMilliseconds / sampleIntervalMilliseconds
        guard samples.indices.contains(index) else { return 0 }
        return samples[index]
    }
}
