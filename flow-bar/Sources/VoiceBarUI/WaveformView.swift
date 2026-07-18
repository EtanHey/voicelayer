// WaveformView.swift — M1-gold rendering over truthful current magnitudes.

import SwiftUI

public struct WaveformView: View {
    public let color: Color
    private let currentLevel: () -> Double?
    private let isListening: Bool
    private let mode: RenderMode

    private let barCount = 7
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    public init(
        color: Color,
        isListening: Bool = false,
        currentLevel: @escaping () -> Double?
    ) {
        self.color = color
        self.isListening = isListening
        self.currentLevel = currentLevel
        mode = .audioDriven
    }

    public init(processingColor color: Color) {
        self.color = color
        isListening = false
        currentLevel = { nil }
        mode = .processing
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            switch mode {
            case .audioDriven:
                AudioDrivenBars(
                    targetLevel: currentLevel(),
                    isListening: isListening,
                    time: now,
                    color: color,
                    barCount: barCount,
                    barWidth: barWidth,
                    barSpacing: barSpacing,
                    maxHeight: maxHeight,
                    minHeight: minHeight,
                    glowOpacity: isListening ? 0.25 : 0.45,
                    glowRadius: isListening ? 3 : 5
                )
            case .processing:
                WaveformBars(
                    normalizedLevels: WaveformMetrics.processingLevels(
                        time: now,
                        barCount: barCount
                    ),
                    color: color,
                    barWidth: barWidth,
                    barSpacing: barSpacing,
                    maxHeight: maxHeight,
                    minHeight: minHeight,
                    glowOpacity: 0.35,
                    glowRadius: 4
                )
            }
        }
    }

    private enum RenderMode {
        case audioDriven
        case processing
    }
}

public enum WaveformMetrics {
    // Keep room tone flat until real speech pushes the local meter above -50 dBFS.
    public static let recordingSilenceFloor = AudioLevelMonitor.normalizeAveragePower(-50)
    public static let envelopeAttackDuration = 0.06
    public static let envelopeReleaseDuration = 0.40
    public static let listeningDamping = 0.7

    public static func recordingLevel(from audioLevel: Double?) -> Double {
        guard let audioLevel, audioLevel.isFinite, audioLevel > recordingSilenceFloor else {
            return 0
        }
        return min(1, (audioLevel - recordingSilenceFloor) / (1 - recordingSilenceFloor))
    }

    public static func envelopeTransitionDuration(from current: Double, to target: Double) -> Double {
        target < current ? envelopeReleaseDuration : envelopeAttackDuration
    }

    public static func audioDrivenLevels(
        level: Double?,
        time: Double,
        barCount: Int,
        isListening: Bool
    ) -> [Double] {
        guard barCount > 0 else { return [] }
        guard let level, level.isFinite, level > 0 else {
            return Array(repeating: 0, count: barCount)
        }

        let truthfulLevel = min(1, max(0, level))
        let displayedLevel = isListening ? truthfulLevel * listeningDamping : truthfulLevel
        return (0 ..< barCount).map { index in
            audioLevelDriven(
                displayedLevel,
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
            return max(0, min(1, normalized))
        }
    }

    private static func phaseOffset(for index: Int) -> Double {
        let phi = 1.618033988749895
        return Double(index) * phi
    }

    private static func centerWeight(index: Int, barCount: Int) -> Double {
        guard barCount > 1 else { return 1 }
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 1 - distance * 0.35
    }

    private static func audioLevelDriven(
        _ level: Double,
        time: Double,
        phaseOffset: Double,
        centerWeight: Double
    ) -> Double {
        let fast = sin(time * 7.0 + phaseOffset * 2.5) * 0.08
        let jitter = sin(time * 12.0 + phaseOffset * 6.0) * 0.05
        let motionScale = 0.4 + level * 0.6
        let base = 0.04 + level * 0.12
        let envelope = pow(level, 0.9) * centerWeight
        return max(0, min(1, base + envelope * 0.82 + (fast + jitter) * motionScale))
    }
}

private struct AudioDrivenBars: View {
    let targetLevel: Double?
    let isListening: Bool
    let time: Double
    let color: Color
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let glowOpacity: Double
    let glowRadius: CGFloat
    @State private var envelopeLevel = 0.0

    var body: some View {
        WaveformBars(
            normalizedLevels: WaveformMetrics.audioDrivenLevels(
                level: envelopeLevel,
                time: time,
                barCount: barCount,
                isListening: isListening
            ),
            color: color,
            barWidth: barWidth,
            barSpacing: barSpacing,
            maxHeight: maxHeight,
            minHeight: minHeight,
            glowOpacity: glowOpacity,
            glowRadius: glowRadius
        )
        .onAppear {
            updateEnvelope(to: targetLevel, animated: false)
        }
        .onChange(of: targetLevel) { _, newLevel in
            updateEnvelope(to: newLevel, animated: true)
        }
    }

    private func updateEnvelope(to rawLevel: Double?, animated: Bool) {
        let target = if let rawLevel, rawLevel.isFinite {
            min(1, max(0, rawLevel))
        } else {
            0.0
        }
        guard animated else {
            envelopeLevel = target
            return
        }

        let duration = WaveformMetrics.envelopeTransitionDuration(
            from: envelopeLevel,
            to: target
        )
        withAnimation(.easeOut(duration: duration)) {
            envelopeLevel = target
        }
    }
}

private struct WaveformBars: View {
    let normalizedLevels: [Double]
    let color: Color
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let glowOpacity: Double
    let glowRadius: CGFloat

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(normalizedLevels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(
                        width: barWidth,
                        height: minHeight +
                            (maxHeight - minHeight) * CGFloat(normalizedLevels[index])
                    )
                    .shadow(color: color.opacity(glowOpacity), radius: glowRadius, y: 0)
            }
        }
        .frame(
            width: CGFloat(normalizedLevels.count) * barWidth +
                CGFloat(max(0, normalizedLevels.count - 1)) * barSpacing,
            height: maxHeight
        )
    }
}
