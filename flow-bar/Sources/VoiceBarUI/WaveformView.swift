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
                audioLevels: nil,
                mapping: .organicReactive
            )
        }
    }

    public init(audioLevels: [Double], color: Color) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: nil,
                audioLevels: audioLevels,
                mapping: .independent
            )
        }
    }

    public init(organicAudioLevels audioLevels: [Double], color: Color) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: nil,
                audioLevels: audioLevels,
                mapping: .organicReactive
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
                audioLevels: nil,
                mapping: .organicReactive
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
                RenderFrame(
                    audioLevel: nil,
                    audioLevels: levels,
                    mapping: .independent
                )
            }
        }
    }

    public init(
        color: Color,
        organicCurrentLevels: @escaping () -> [Double]?
    ) {
        self.color = color
        currentFrame = {
            organicCurrentLevels().map { levels in
                RenderFrame(
                    audioLevel: nil,
                    audioLevels: levels,
                    mapping: .organicReactive
                )
            }
        }
    }

    public init(processingColor color: Color) {
        self.color = color
        currentFrame = {
            RenderFrame(
                audioLevel: nil,
                audioLevels: nil,
                mapping: .processing
            )
        }
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let frame = currentFrame()
            let normalizedLevels = frame.map { frame in
                switch frame.mapping {
                case .organicReactive:
                    if let audioLevels = frame.audioLevels {
                        return WaveformMetrics.organicLevels(
                            audioLevels: audioLevels,
                            time: now,
                            barCount: barCount
                        )
                    }
                    return WaveformMetrics.organicLevels(
                        audioLevels: [frame.audioLevel ?? 0],
                        time: now,
                        barCount: barCount
                    )
                case .processing:
                    return WaveformMetrics.processingLevels(time: now, barCount: barCount)
                case .independent:
                    return WaveformMetrics.normalizedLevels(
                        audioLevels: frame.audioLevels ?? [],
                        barCount: barCount
                    )
                }
            }
            HStack(spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        targetNormalizedLevel: normalizedLevels?[index] ?? 0,
                        color: color,
                        maxHeight: maxHeight,
                        minHeight: minHeight,
                        barWidth: barWidth,
                        index: index,
                        barCount: barCount,
                        isVisible: frame != nil,
                        usesReactiveTransition: frame?.mapping == .organicReactive,
                        usesImmediateTransition: frame?.mapping == .processing
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
        let mapping: RenderMapping
    }

    private enum RenderMapping {
        case organicReactive
        case processing
        case independent
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

    public static func organicLevels(
        audioLevels: [Double],
        time: Double,
        barCount: Int
    ) -> [Double] {
        guard barCount > 0 else { return [] }
        guard let currentMagnitude = audioLevels.last,
              currentMagnitude.isFinite,
              currentMagnitude > 0
        else { return Array(repeating: 0, count: barCount) }
        let level = min(1, currentMagnitude)
        return (0 ..< barCount).map { index in
            organicLevel(
                level: level,
                time: time,
                phaseOffset: phaseOffset(for: index),
                centerWeight: centerWeight(index: index, barCount: barCount)
            )
        }
    }

    public static func processingLevels(time: Double, barCount: Int) -> [Double] {
        guard barCount > 0 else { return [] }
        return (0 ..< barCount).map { index in
            let center = Double(barCount - 1) / 2
            let distanceFromCenter = abs(Double(index) - center)
            let normalizedDistance = center == 0 ? 0 : distanceFromCenter / center
            let inwardOutward = sin(time * 4.8 - normalizedDistance * .pi) * 0.5 + 0.5
            let centerPulse = sin(time * 2.4) * 0.5 + 0.5
            let normalized = 0.12
                + inwardOutward * 0.38
                + centerPulse * 0.16 * centerWeight(index: index, barCount: barCount)
            return min(1, max(0, normalized))
        }
    }

    public static func reactiveTransitionDuration(from current: Double, to target: Double) -> Double {
        target < current ? minimumLiveReleaseDuration : minimumLiveAttackDuration
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

    private static func phaseOffset(for index: Int) -> Double {
        let phi = 1.618033988749895
        return Double(index) * phi
    }

    private static func organicLevel(
        level: Double,
        time: Double,
        phaseOffset: Double,
        centerWeight: Double
    ) -> Double {
        let fast = sin(time * 7 + phaseOffset * 2.5) * 0.08
        let jitter = sin(time * 12 + phaseOffset * 6)
            * sin(time * 9.1 + phaseOffset * 5.2)
            * 0.05
        let motionScale = 0.4 + level * 0.6
        let base = 0.04 + level * 0.12
        let envelope = pow(level, 0.9) * centerWeight
        return min(1, max(0, base + envelope * 0.82 + (fast + jitter) * motionScale))
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
    let usesReactiveTransition: Bool
    let usesImmediateTransition: Bool
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
                if usesImmediateTransition {
                    displayedNormalizedLevel = newLevel
                    return
                }
                let duration = if usesReactiveTransition {
                    WaveformMetrics.reactiveTransitionDuration(
                        from: displayedNormalizedLevel,
                        to: newLevel
                    )
                } else {
                    WaveformMetrics.transitionDuration(
                        from: displayedNormalizedLevel,
                        to: newLevel,
                        index: index,
                        barCount: barCount
                    )
                }
                withAnimation(.easeOut(duration: duration)) {
                    displayedNormalizedLevel = newLevel
                }
            }
    }

    private var barHeight: CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(displayedNormalizedLevel)
    }
}
