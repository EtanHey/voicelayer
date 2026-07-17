// WaveformView.swift — One truthful seven-bar amplitude renderer.

import SwiftUI

public struct WaveformView: View {
    public let color: Color
    private let currentLevel: () -> Double?

    private let barCount = 7
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    public init(audioLevel: Double?, color: Color) {
        self.color = color
        currentLevel = { audioLevel }
    }

    public init(
        color: Color,
        currentLevel: @escaping () -> Double?
    ) {
        self.color = color
        self.currentLevel = currentLevel
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            let audioLevel = currentLevel()
            HStack(spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        normalizedLevel: WaveformMetrics.normalizedLevel(
                            audioLevel: audioLevel,
                            index: index,
                            barCount: barCount
                        ),
                        color: color,
                        maxHeight: maxHeight,
                        minHeight: minHeight,
                        barWidth: barWidth
                    )
                    .frame(width: barWidth)
                }
            }
            .frame(width: totalWidth, height: maxHeight)
        }
    }

    private var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }
}

public enum WaveformMetrics {
    /// AudioLevelMonitor uses a -120...0 dB display scale, so observed room
    /// tone lands near 0.58 rather than zero. Adapt that source once before the
    /// shared geometry; playback envelopes already use their own fixed -60 dBFS
    /// scale and must not pass through this gate.
    public static let recordingSilenceFloor = AudioLevelMonitor.normalizeAveragePower(-50)

    public static func recordingLevel(from audioLevel: Double?) -> Double {
        guard let audioLevel, audioLevel.isFinite, audioLevel > recordingSilenceFloor else {
            return 0
        }
        return min(1, (audioLevel - recordingSilenceFloor) / (1 - recordingSilenceFloor))
    }

    public static func normalizedLevel(
        audioLevel: Double?,
        index: Int,
        barCount: Int
    ) -> Double {
        guard let audioLevel, audioLevel.isFinite, audioLevel > 0 else { return 0 }

        let clampedLevel = min(1, audioLevel)
        return clampedLevel * centerWeight(index: index, barCount: barCount)
    }

    private static func centerWeight(index: Int, barCount: Int) -> Double {
        guard barCount > 1 else { return 1 }
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / max(center, 1)
        return 1 - min(1, distance) * 0.35
    }
}

private struct WaveformBar: View {
    let normalizedLevel: Double
    let color: Color
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let barWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(height: barHeight)
            .shadow(color: color.opacity(0.35), radius: 4)
    }

    private var barHeight: CGFloat {
        minHeight + (maxHeight - minHeight) * normalizedLevel
    }
}
