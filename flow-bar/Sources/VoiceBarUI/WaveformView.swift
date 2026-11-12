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

/// c9-P: how far the meter has handed over from its live drive (the red level meter) to the processing ripple.
/// The bars stay one view: their heights and colour blend over `duration`, so nothing leaves or re-enters the slot.
/// The first sample lands at its target, so a meter that first appears transcribing shows the ripple at once.
public struct WaveformProcessingHandover {
    public static let duration = 0.45
    private var target: Bool?
    private var linearProgress = 0.0
    private var lastSampleTime: Double?

    public init() {}

    /// The eased progress (0 = live drive, 1 = processing ripple) at `time`.
    @discardableResult
    public mutating func progress(isProcessing: Bool, at time: Double) -> Double {
        let goal = isProcessing ? 1.0 : 0.0
        guard target != nil, let lastSampleTime, time.isFinite else {
            target = isProcessing
            linearProgress = goal
            self.lastSampleTime = time.isFinite ? time : nil
            return goal
        }
        target = isProcessing
        let elapsed = max(0, time - lastSampleTime)
        self.lastSampleTime = time
        let step = elapsed / Self.duration
        linearProgress = goal > linearProgress
            ? min(goal, linearProgress + step)
            : max(goal, linearProgress - step)
        return Self.eased(linearProgress)
    }

    /// Ease-in-out on the colour and drive, so the hand-over neither snaps at its start nor stops dead.
    public static func eased(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}

private final class WaveformEnvelopeStore: ObservableObject {
    private var follower = WaveformEnvelopeFollower()
    private var handover = WaveformProcessingHandover()

    func sample(rawLevel: Double?, at time: Double) -> Double {
        follower.sample(rawLevel: rawLevel, at: time)
    }

    func processingProgress(isProcessing: Bool, at time: Double) -> Double {
        handover.progress(isProcessing: isProcessing, at: time)
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

// A fixture may freeze decorative animation without changing capture or playback clocks.
private struct VisualRenderTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}
extension EnvironmentValues {
    var visualRenderTime: Double? {
        get { self[VisualRenderTimeKey.self] }
        set { self[VisualRenderTimeKey.self] = newValue }
    }
}

public struct WaveformView: View {
    @Environment(\.visualRenderTime) private var renderTime
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.voiceBarReduceMotionOverride) private var reduceMotionOverride
    public let color: Color
    /// c9-P: the ripple's colour. `color` stays the live drive's, so a meter handing over to the ripple blends
    /// one into the other on the same bars.
    public let processingColor: Color
    private let currentLevel: () -> Double?
    private let isListening: Bool
    private let mode: RenderMode
    private let isPaused: Bool
    @StateObject private var envelopeStore = WaveformEnvelopeStore()

    private let barCount = WaveformLayout.barCount
    private let barWidth = WaveformLayout.barWidth
    private let barSpacing = WaveformLayout.barSpacing
    private let maxHeight = WaveformLayout.viewportHeight
    private let minHeight: CGFloat = 3

    public init(
        color: Color,
        processingColor: Color? = nil,
        isListening: Bool = false,
        isProcessing: Bool = false,
        isBooting: Bool = false,
        isPaused: Bool = false,
        currentLevel: @escaping () -> Double?
    ) {
        self.color = color
        self.processingColor = processingColor ?? color
        self.isListening = isListening
        self.isPaused = isPaused
        self.currentLevel = currentLevel
        // Booting outranks every other treatment: until the recorder delivers a
        // frame there is nothing truthful to animate.
        mode = if isBooting {
            .booting
        } else if isProcessing {
            .processing
        } else {
            .audioDriven
        }
    }

    public init(processingColor color: Color) {
        self.color = color
        processingColor = color
        isListening = false
        isPaused = false
        currentLevel = { nil }
        mode = .processing
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused || renderTime != nil)) { timeline in
            let now = renderTime ?? timeline.date.timeIntervalSinceReferenceDate
            // The live drive keeps sampling through a hand-over (a transcribing meter's level is nil), so the red
            // meter releases while it fades.
            let envelopeLevel = mode != .booting && !isPaused
                ? envelopeStore.sample(rawLevel: currentLevel(), at: now)
                : 0
            let processingProgress = mode == .booting
                ? 0
                : envelopeStore.processingProgress(isProcessing: mode == .processing, at: now)
            TimelineSample(
                envelopeLevel: envelopeLevel,
                processingProgress: processingProgress,
                reduceMotion: reduceMotionOverride ?? systemReduceMotion,
                time: now,
                color: color,
                processingColor: processingColor,
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
        /// Pressed, mic not yet capturing — a flat, unanimated, gray bed.
        case booting
    }

    private struct TimelineSample: View {
        let envelopeLevel: Double
        /// 0 = the live drive, 1 = the processing ripple (c9-P hand-over).
        let processingProgress: Double
        let reduceMotion: Bool
        let time: Double
        let color: Color
        let processingColor: Color
        let isListening: Bool
        let mode: RenderMode
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let maxHeight: CGFloat
        let minHeight: CGFloat

        var body: some View {
            let progress = mode == .booting ? 0 : processingProgress
            let layers = WaveformMetrics.handoverLayerOpacities(progress: progress, rippleOpacity: processingOpacity)
            WaveformBars(
                normalizedLevels: normalizedLevels(time: time, progress: progress),
                color: color,
                colorOpacity: layers.drive,
                overlayColor: processingColor,
                overlayOpacity: layers.ripple,
                barWidth: barWidth,
                barSpacing: barSpacing,
                maxHeight: maxHeight,
                minHeight: minHeight,
                glowOpacity: driveGlowOpacity * (1 - progress),
                glowRadius: driveGlowRadius,
                overlayGlowOpacity: 0.35 * progress,
                overlayGlowRadius: 4
            )
        }

        private func normalizedLevels(time: Double, progress: Double) -> [Double] {
            switch mode {
            case .booting:
                return WaveformMetrics.bootingLevels(barCount: barCount)
            case .audioDriven, .processing:
                let drive = WaveformMetrics.audioDrivenLevels(
                    level: envelopeLevel,
                    time: time,
                    barCount: barCount,
                    isListening: isListening
                )
                guard progress > 0 else { return drive }
                let ripple = reduceMotion
                    ? WaveformMetrics.processingLevelsReducedMotion(barCount: barCount)
                    : WaveformMetrics.processingLevels(time: time, barCount: barCount)
                return WaveformMetrics.handoverLevels(from: drive, to: ripple, progress: progress)
            }
        }

        /// Reduce Motion: no ripple travels; the still arch breathes in place instead.
        private var processingOpacity: Double {
            reduceMotion ? WaveformMetrics.processingReducedMotionOpacity(time: time) : 1
        }

        private var driveGlowOpacity: Double {
            switch mode {
            case .audioDriven, .processing: isListening ? 0.25 : 0.45
            case .booting: 0
            }
        }

        private var driveGlowRadius: CGFloat {
            switch mode {
            case .audioDriven, .processing: isListening ? 3 : 5
            case .booting: 0
            }
        }
    }
}

public struct VoiceBarNotchWaveform: View {
    public let mode: VoiceMode
    public let isListening: Bool
    /// False while `.recording` is still optimistic — the press registered but
    /// the recorder has not handed over a frame yet.
    public let isCaptureLive: Bool
    private let recordingLevel: () -> Double?
    private let playbackLevel: () -> Double?
    /// An ended readback keeps the teleprompter wing filled with a still, dimmed bed.
    public let isPlaybackEnded: Bool

    public init(
        mode: VoiceMode,
        isListening: Bool,
        isCaptureLive: Bool,
        recordingLevel: @escaping () -> Double?,
        playbackLevel: @escaping () -> Double?,
        isPlaybackEnded: Bool = false
    ) {
        self.isPlaybackEnded = isPlaybackEnded
        self.mode = mode
        self.isListening = isListening
        self.isCaptureLive = isCaptureLive
        self.recordingLevel = recordingLevel
        self.playbackLevel = playbackLevel
    }

    public var body: some View {
        WaveformView(
            // c9-P: while transcribing, the drive colour is the red the meter is handing over from.
            color: mode == .transcribing
                ? Theme.recordingColor
                : Self.waveformColor(mode: mode, isCaptureLive: isCaptureLive, isPlaybackEnded: isPlaybackEnded),
            processingColor: Self.waveformColor(mode: .transcribing, isCaptureLive: true),
            isListening: mode == .recording && isListening,
            isProcessing: mode == .transcribing,
            isBooting: isBooting,
            isPaused: isPlaybackEnded,
            currentLevel: currentLevel
        )
    }

    /// Red is reserved for a capture that actually exists.
    public static func waveformColor(mode: VoiceMode, isCaptureLive: Bool, isPlaybackEnded: Bool = false) -> Color {
        if isPlaybackEnded, mode == .idle { return Theme.speakingColor.opacity(0.45) }
        return switch mode {
        case .recording:
            isCaptureLive ? Theme.recordingColor : Theme.captureBootingColor
        case .transcribing:
            // c9-P: the ripple's lifted processing blue (contrast on the M4 glass).
            Theme.processingRippleColor
        case .speaking:
            Theme.speakingColor
        case .idle, .error, .disconnected:
            .clear
        }
    }

    private var isBooting: Bool {
        mode == .recording && !isCaptureLive
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

    /// A booting waveform carries no amplitude: every bar collapses to the
    /// shared minimum height, so the seven dots sit flat on the centerline and
    /// nothing moves until real audio arrives.
    public static func bootingLevels(barCount: Int) -> [Double] {
        guard barCount > 0 else { return [] }
        return Array(repeating: 0, count: barCount)
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

    /// c9-P Reduce Motion: the ripple's mean shape, held still (no travel between bars).
    public static func processingLevelsReducedMotion(barCount: Int) -> [Double] {
        guard barCount > 0 else { return [] }
        return (0 ..< barCount).map { index in
            max(0, min(1, 0.12 + 0.5 * 0.38 + 0.5 * 0.16 * centerWeight(index: index, barCount: barCount)))
        }
    }

    /// c9-P Reduce Motion: the still ripple breathes between 70 % and 100 % on the slow 2.6 s centre pulse.
    public static func processingReducedMotionOpacity(time: Double) -> Double {
        0.85 + 0.15 * sin(time * 2.4)
    }

    /// c9-P: the two layers' opacities for a hand-over at `progress` (0 = drive, 1 = ripple). The ripple is drawn
    /// over the drive on the same bars; together they show the drive and ripple colours mixed by `progress` at a
    /// total opacity of `1 - progress + progress * rippleOpacity` (`rippleOpacity` < 1 only for Reduce Motion's
    /// breathing), so the colour moves without the bars thinning out mid-way.
    public static func handoverLayerOpacities(progress: Double, rippleOpacity: Double = 1)
        -> (drive: Double, ripple: Double) {
        let p = min(1, max(0, progress))
        let total = 1 - p + p * min(1, max(0, rippleOpacity))
        let ripple = p * total
        let drive = ripple >= 1 || p >= 1 ? 0 : total * (1 - p) / (1 - ripple)
        return (drive, ripple)
    }

    /// c9-P: the hand-over from the live meter to the ripple blends each bar's height; bar positions never change.
    public static func handoverLevels(from drive: [Double], to ripple: [Double], progress: Double) -> [Double] {
        let p = min(1, max(0, progress))
        return zip(drive, ripple).map { from, to in from + (to - from) * p }
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
    var colorOpacity: Double = 1
    /// c9-P: drawn over `color` on the same bars, so a hand-over is a true colour blend at full coverage.
    var overlayColor: Color = .clear
    var overlayOpacity: Double = 0
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let glowOpacity: Double
    let glowRadius: CGFloat
    var overlayGlowOpacity: Double = 0
    var overlayGlowRadius: CGFloat = 0

    var body: some View {
        Canvas { context, _ in
            let bars = Path { path in
                for index in normalizedLevels.indices {
                    let frame = WaveformBarGeometry.frame(
                        index: index,
                        normalizedLevel: normalizedLevels[index],
                        barWidth: barWidth,
                        barSpacing: barSpacing,
                        maxHeight: maxHeight,
                        minHeight: minHeight
                    )
                    path.addPath(Path(roundedRect: frame, cornerRadius: barWidth / 2))
                }
            }
            if colorOpacity > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: color.opacity(glowOpacity), radius: glowRadius))
                    layer.fill(bars, with: .color(color.opacity(colorOpacity)))
                }
            }
            // The glow follows the hand-over too: the drive's glow fades as the ripple's rises.
            if overlayOpacity > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: overlayColor.opacity(overlayGlowOpacity), radius: overlayGlowRadius))
                    layer.fill(bars, with: .color(overlayColor.opacity(overlayOpacity)))
                }
            }
        }
        .frame(
            width: CGFloat(normalizedLevels.count) * barWidth +
                CGFloat(max(0, normalizedLevels.count - 1)) * barSpacing,
            height: maxHeight
        )
    }
}
