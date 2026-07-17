// WaveformView.swift — One truthful seven-bar amplitude renderer.

import SwiftUI

public struct WaveformView: View {
    public let color: Color
    private let currentFrame: () -> RenderFrame?

    private let barCount = 7
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    public init(audioLevel: Double?, color: Color) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: audioLevel,
                audioLevels: nil
            )
        }
    }

    public init(audioLevels: [Double], color: Color) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: nil,
                audioLevels: audioLevels
            )
        }
    }

    public init(
        color: Color,
        currentLevel: @escaping () -> Double?
    ) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: currentLevel(),
                audioLevels: nil
            )
        }
    }

    public init(
        color: Color,
        currentLevels: @escaping () -> [Double]?
    ) {
        self.color = color
        currentFrame = {
            currentLevels().map { levels in
                RenderFrame(audioLevel: nil, audioLevels: levels)
            }
        }
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            let frame = currentFrame()
            let independentLevels = frame.map { frame in
                WaveformMetrics.normalizedLevels(
                    audioLevels: frame.audioLevels ?? [],
                    barCount: barCount
                )
            }
            HStack(spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        targetNormalizedLevel: frame?.audioLevels != nil
                            ? independentLevels?[index] ?? 0
                            : WaveformMetrics.normalizedLevel(
                                audioLevel: frame?.audioLevel,
                                index: index,
                                barCount: barCount
                            ),
                        color: color,
                        maxHeight: maxHeight,
                        minHeight: minHeight,
                        barWidth: barWidth,
                        index: index,
                        barCount: barCount,
                        isVisible: frame != nil
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

    private struct RenderFrame {
        let audioLevel: Double?
        let audioLevels: [Double]?
    }
}

public enum WaveformMetrics {
    /// AudioLevelMonitor uses a -120...0 dB display scale, so observed room
    /// tone lands near 0.58 rather than zero. Adapt that source once before the
    /// shared geometry; playback envelopes already use their own fixed -60 dBFS
    /// scale and must not pass through this gate.
    public static let recordingSilenceFloor = AudioLevelMonitor.normalizeAveragePower(-50)
    public static let minimumLiveAttackDuration = 0.10
    public static let maximumLiveAttackDuration = 0.20
    public static let minimumLiveReleaseDuration = 0.18
    public static let maximumLiveReleaseDuration = 0.30

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

    public static func normalizedLevels(audioLevels: [Double], barCount: Int) -> [Double] {
        guard barCount > 0 else { return [] }
        let realLevels = audioLevels.suffix(barCount).map { level in
            level.isFinite ? min(1, max(0, level)) : 0
        }
        return Array(repeating: 0, count: max(0, barCount - realLevels.count)) + realLevels
    }

    public static func transitionDuration(
        from current: Double,
        to target: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let minimumDuration = target < current
            ? minimumLiveReleaseDuration
            : minimumLiveAttackDuration
        let maximumDuration = target < current
            ? maximumLiveReleaseDuration
            : maximumLiveAttackDuration
        guard barCount > 1 else { return maximumDuration }
        let boundedIndex = min(max(index, 0), barCount - 1)
        let stagger = (boundedIndex * 3) % barCount
        let progress = Double(stagger) / Double(barCount - 1)
        return minimumDuration + progress * (maximumDuration - minimumDuration)
    }

    private static func centerWeight(index: Int, barCount: Int) -> Double {
        guard barCount > 1 else { return 1 }
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / max(center, 1)
        return 1 - min(1, distance) * 0.35
    }
}

private struct WaveformBar: View {
    let targetNormalizedLevel: Double
    let color: Color
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let barWidth: CGFloat
    let index: Int
    let barCount: Int
    let isVisible: Bool
    @State private var displayedNormalizedLevel = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(height: barHeight)
            .opacity(isVisible ? 1 : 0)
            .shadow(color: color.opacity(0.35), radius: 4)
            .onAppear {
                displayedNormalizedLevel = targetNormalizedLevel
            }
            .onChange(of: targetNormalizedLevel) { _, newLevel in
                let duration = WaveformMetrics.transitionDuration(
                    from: displayedNormalizedLevel,
                    to: newLevel,
                    index: index,
                    barCount: barCount
                )
                withAnimation(.easeOut(duration: duration)) {
                    displayedNormalizedLevel = newLevel
                }
            }
    }

    private var barHeight: CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(displayedNormalizedLevel)
    }
}
