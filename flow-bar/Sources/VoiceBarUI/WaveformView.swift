// WaveformView.swift — M1-gold rendering over truthful current magnitudes.

import SwiftUI

public enum WaveformLayout {
    public static let barCount = 7
    public static let barWidth: CGFloat = 4
    public static let barSpacing: CGFloat = 3
    public static let viewportWidth: CGFloat = 46
    public static let viewportHeight: CGFloat = 24
    public static let coreGap: CGFloat = 24
    public static let outerInset: CGFloat = 8

    public static func leadingX(coreMaxX: CGFloat) -> CGFloat {
        coreMaxX + coreGap
    }
}

public struct WaveformEnvelopeFollower {
    public private(set) var level = 0.0
    private var lastSampleTime: Double?
    private var releaseStartTime: Double?
    private var releaseStartLevel = 0.0

    public init() {}

    @discardableResult
    public mutating func sample(rawLevel: Double?, at time: Double) -> Double {
        let target = if let rawLevel, rawLevel.isFinite {
            min(1, max(0, rawLevel))
        } else {
            0.0
        }
        guard time.isFinite else { return level }
        guard let lastSampleTime else {
            lastSampleTime = time
            level = target
            return level
        }

        let previousSampleTime = lastSampleTime
        let elapsed = max(0, time - previousSampleTime)
        self.lastSampleTime = time
        guard elapsed > 0 else { return level }

        if target == 0 {
            guard level > 0 else {
                releaseStartTime = nil
                releaseStartLevel = 0
                return 0
            }
            if releaseStartTime == nil {
                releaseStartTime = previousSampleTime
                releaseStartLevel = level
            }
            let releaseElapsed = max(0, time - (releaseStartTime ?? previousSampleTime))
            let releaseProgress = min(
                1,
                releaseElapsed / WaveformMetrics.envelopeReleaseDuration
            )
            level = releaseStartLevel * (1 - releaseProgress)
            if releaseProgress >= 1 {
                releaseStartTime = nil
                releaseStartLevel = 0
            }
            return level
        }

        releaseStartTime = nil
        releaseStartLevel = 0

        let duration = WaveformMetrics.envelopeTransitionDuration(
            from: level,
            to: target
        )
        let progress = 1 - exp(-3 * elapsed / duration)
        level += (target - level) * progress

        if abs(target - level) <= 0.01 {
            level = target
        }
        return level
    }
}

private final class WaveformEnvelopeStore: ObservableObject {
    private var follower = WaveformEnvelopeFollower()

    func sample(rawLevel: Double?, at time: Double) -> Double {
        follower.sample(rawLevel: rawLevel, at: time)
    }
}

public enum WaveformBarGeometry {
    public static func frame(
        index: Int,
        normalizedLevel: Double,
        barWidth: CGFloat,
        barSpacing: CGFloat,
        maxHeight: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let level = normalizedLevel.isFinite
            ? min(1, max(0, normalizedLevel))
            : 0
        let height = minHeight + (maxHeight - minHeight) * CGFloat(level)
        return CGRect(
            x: CGFloat(index) * (barWidth + barSpacing),
            y: (maxHeight - height) / 2,
            width: barWidth,
            height: height
        )
    }
}

public struct WaveformView: View {
    public let color: Color
    private let currentLevel: () -> Double?
    private let isListening: Bool
    private let mode: RenderMode
    @StateObject private var envelopeStore = WaveformEnvelopeStore()

    private let barCount = WaveformLayout.barCount
    private let barWidth = WaveformLayout.barWidth
    private let barSpacing = WaveformLayout.barSpacing
    private let maxHeight = WaveformLayout.viewportHeight
    private let minHeight: CGFloat = 3

    public init(
        color: Color,
        isListening: Bool = false,
        isProcessing: Bool = false,
        currentLevel: @escaping () -> Double?
    ) {
        self.color = color
        self.isListening = isListening
        self.currentLevel = currentLevel
        mode = isProcessing ? .processing : .audioDriven
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
            let envelopeLevel = mode == .audioDriven
                ? envelopeStore.sample(rawLevel: currentLevel(), at: now)
                : 0
            TimelineSample(
                envelopeLevel: envelopeLevel,
                time: now,
                color: color,
                isListening: isListening,
                mode: mode,
                barCount: barCount,
                barWidth: barWidth,
                barSpacing: barSpacing,
                maxHeight: maxHeight,
                minHeight: minHeight
            )
        }
        .frame(width: WaveformLayout.viewportWidth, height: WaveformLayout.viewportHeight)
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(1)
    }

    private enum RenderMode: Equatable {
        case audioDriven
        case processing
    }

    private struct TimelineSample: View {
        let envelopeLevel: Double
        let time: Double
        let color: Color
        let isListening: Bool
        let mode: RenderMode
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let maxHeight: CGFloat
        let minHeight: CGFloat

        var body: some View {
            WaveformBars(
                normalizedLevels: normalizedLevels(time: time),
                color: color,
                barWidth: barWidth,
                barSpacing: barSpacing,
                maxHeight: maxHeight,
                minHeight: minHeight,
                glowOpacity: glowOpacity,
                glowRadius: glowRadius
            )
        }

        private func normalizedLevels(time: Double) -> [Double] {
            switch mode {
            case .audioDriven:
                WaveformMetrics.audioDrivenLevels(
                    level: envelopeLevel,
                    time: time,
                    barCount: barCount,
                    isListening: isListening
                )
            case .processing:
                WaveformMetrics.processingLevels(time: time, barCount: barCount)
            }
        }

        private var glowOpacity: Double {
            switch mode {
            case .audioDriven: isListening ? 0.25 : 0.45
            case .processing: 0.35
            }
        }

        private var glowRadius: CGFloat {
            switch mode {
            case .audioDriven: isListening ? 3 : 5
            case .processing: 4
            }
        }
    }
}

public struct VoiceBarNotchWaveform: View {
    public let mode: VoiceMode
    public let isListening: Bool
    private let recordingLevel: () -> Double?
    private let playbackLevel: () -> Double?

    public init(
        mode: VoiceMode,
        isListening: Bool,
        recordingLevel: @escaping () -> Double?,
        playbackLevel: @escaping () -> Double?
    ) {
        self.mode = mode
        self.isListening = isListening
        self.recordingLevel = recordingLevel
        self.playbackLevel = playbackLevel
    }

    public var body: some View {
        WaveformView(
            color: color,
            isListening: mode == .recording && isListening,
            isProcessing: mode == .transcribing,
            currentLevel: currentLevel
        )
    }

    private var color: Color {
        switch mode {
        case .recording:
            Theme.recordingColor
        case .transcribing:
            Theme.stateColor(for: .transcribing)
        case .speaking:
            Theme.speakingColor
        case .idle, .error, .disconnected:
            .clear
        }
    }

    private func currentLevel() -> Double? {
        switch mode {
        case .recording:
            recordingLevel()
        case .speaking:
            playbackLevel()
        case .idle, .transcribing, .error, .disconnected:
            nil
        }
    }
}

public enum WaveformMetrics {
    // Keep room tone flat until real speech pushes the local meter above -50 dBFS.
    public static let recordingSilenceFloor = AudioLevelMonitor.normalizeAveragePower(-50)
    public static let envelopeAttackDuration = 0.08
    public static let envelopeReleaseDuration = 0.20
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
        Canvas { context, _ in
            context.addFilter(
                .shadow(
                    color: color.opacity(glowOpacity),
                    radius: glowRadius,
                    x: 0,
                    y: 0
                )
            )
            for index in normalizedLevels.indices {
                let frame = WaveformBarGeometry.frame(
                    index: index,
                    normalizedLevel: normalizedLevels[index],
                    barWidth: barWidth,
                    barSpacing: barSpacing,
                    maxHeight: maxHeight,
                    minHeight: minHeight
                )
                context.fill(
                    Path(
                        roundedRect: frame,
                        cornerRadius: barWidth / 2
                    ),
                    with: .color(color)
                )
            }
        }
        .frame(
            width: CGFloat(normalizedLevels.count) * barWidth +
                CGFloat(max(0, normalizedLevels.count - 1)) * barSpacing,
            height: maxHeight
        )
    }
}
