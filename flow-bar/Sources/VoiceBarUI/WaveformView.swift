// WaveformView.swift — Animated 7-bar waveform visualization.
//
// Three modes:
//   idle           — gentle breathing, barely visible
//   listening      — minimal bars until real audio arrives, then audio-driven
//   speechDetected — active, lively movement
//   processing     — blue synthetic motion while STT runs
//
// Uses TimelineView at 60fps. Recording modes stay organic; processing mode
// is intentionally symmetrical/mechanical so it reads as compute, not speech.

import SwiftUI

// MARK: - Waveform Mode (visual, not voice state)

public enum WaveformMode: String, CaseIterable {
    case idle
    case listening
    case speechDetected
    case processing
}

// MARK: - Waveform View

public struct WaveformView: View {
    public let mode: WaveformMode
    public let audioLevel: Double?
    @State private var listeningEnvelopeLevel: Double = 0

    private let barCount = 7
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    init(mode: WaveformMode, audioLevel: Double? = nil) {
        self.mode = mode
        self.audioLevel = audioLevel
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        index: index,
                        barCount: barCount,
                        time: now,
                        mode: mode,
                        audioLevel: displayedAudioLevel,
                        maxHeight: maxHeight,
                        minHeight: minHeight,
                        barWidth: barWidth
                    )
                    .frame(width: barWidth)
                }
            }
            .frame(width: totalWidth, height: maxHeight)
        }
        .onAppear {
            updateListeningEnvelope(for: audioLevel, animated: false)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .listening {
                updateListeningEnvelope(for: audioLevel, animated: false)
            } else {
                listeningEnvelopeLevel = audioLevel ?? 0
            }
        }
        .onChange(of: audioLevel) { _, newLevel in
            if mode == .listening {
                updateListeningEnvelope(for: newLevel, animated: true)
            } else {
                listeningEnvelopeLevel = newLevel ?? 0
            }
        }
    }

    private var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    private var displayedAudioLevel: Double? {
        switch mode {
        case .listening:
            listeningEnvelopeLevel
        case .idle, .speechDetected, .processing:
            audioLevel
        }
    }

    private func updateListeningEnvelope(for rawLevel: Double?, animated: Bool) {
        let targetLevel = WaveformMetrics.listeningTargetLevel(from: rawLevel)
        if targetLevel >= listeningEnvelopeLevel {
            guard animated else {
                listeningEnvelopeLevel = targetLevel
                return
            }

            withAnimation(.easeOut(duration: WaveformMetrics.listeningAttackDuration)) {
                listeningEnvelopeLevel = targetLevel
            }
            return
        }

        guard animated else {
            listeningEnvelopeLevel = targetLevel
            return
        }

        withAnimation(.easeOut(duration: WaveformMetrics.listeningReleaseDuration)) {
            listeningEnvelopeLevel = targetLevel
        }
    }
}

public enum WaveformMetrics {
    // Keep the listening waveform flat around typical room tone
    // until real speech pushes the local meter above roughly -50 dBFS.
    public static let listeningSilenceFloor = AudioLevelMonitor.normalizeAveragePower(-50)
    public static let listeningAttackDuration = 0.06
    public static let listeningReleaseDuration = 0.40

    public static func listeningTargetLevel(from audioLevel: Double?) -> Double {
        guard let audioLevel, audioLevel >= listeningSilenceFloor else { return 0 }
        return (audioLevel - listeningSilenceFloor) / (1 - listeningSilenceFloor)
    }

    public static func normalizedLevel(
        mode: WaveformMode,
        audioLevel: Double?,
        time: Double,
        index: Int,
        barCount: Int
    ) -> Double {
        let phaseOffset = Self.phaseOffset(for: index)
        let centerWeight = Self.centerWeight(index: index, barCount: barCount)

        let normalized: Double = switch mode {
        case .idle:
            idleLevel(time: time, phaseOffset: phaseOffset, centerWeight: centerWeight)
        case .processing:
            processingLevel(time: time, index: index, barCount: barCount, centerWeight: centerWeight)
        case .listening:
            if let level = audioLevel, level > 0 {
                audioLevelDriven(
                    level * 0.7,
                    time: time,
                    phaseOffset: phaseOffset,
                    centerWeight: centerWeight
                )
            } else {
                0
            }
        case .speechDetected:
            if let level = audioLevel {
                audioLevelDriven(
                    level,
                    time: time,
                    phaseOffset: phaseOffset,
                    centerWeight: centerWeight
                )
            } else {
                speechSimulatedLevel(time: time, phaseOffset: phaseOffset, centerWeight: centerWeight)
            }
        }

        return max(0, min(1, normalized))
    }

    private static func phaseOffset(for index: Int) -> Double {
        let phi = 1.618033988749895
        return Double(index) * phi
    }

    private static func centerWeight(index: Int, barCount: Int) -> Double {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        return 1.0 - distance * 0.35
    }

    private static func idleLevel(time: Double, phaseOffset: Double, centerWeight: Double) -> Double {
        let breath = sin(time * 1.2 + phaseOffset * 2.0) * 0.5 + 0.5
        let shimmer = sin(time * 3.7 + phaseOffset * 5.0) * 0.03
        return 0.05 + breath * 0.1 * centerWeight + shimmer
    }

    private static func speechSimulatedLevel(
        time: Double,
        phaseOffset: Double,
        centerWeight: Double
    ) -> Double {
        let fast = sin(time * 8.5 + phaseOffset * 2.3) * 0.25
        let medium = sin(time * 4.2 + phaseOffset * 3.7) * 0.2
        let slow = sin(time * 1.8 + phaseOffset * 1.1) * 0.15
        let pulse = sin(time * 6.1 + phaseOffset * 4.9) * 0.1
        let jitter = sin(time * 13.7 + phaseOffset * 7.3) * sin(time * 9.1 + phaseOffset * 5.2) * 0.12
        let base = 0.55 * centerWeight
        return base + fast + medium + slow + pulse + jitter
    }

    private static func processingLevel(
        time: Double,
        index: Int,
        barCount: Int,
        centerWeight: Double
    ) -> Double {
        let center = Double(barCount - 1) / 2.0
        let distanceFromCenter = abs(Double(index) - center)
        let normalizedDistance = center == 0 ? 0 : distanceFromCenter / center
        let inwardOutward = sin(time * 4.8 - normalizedDistance * .pi) * 0.5 + 0.5
        let centerPulse = sin(time * 2.4) * 0.5 + 0.5
        return 0.12 + inwardOutward * 0.38 + centerPulse * 0.16 * centerWeight
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
        return base + envelope * 0.82 + (fast + jitter) * motionScale
    }
}

// MARK: - Individual Bar

private struct WaveformBar: View {
    public let index: Int
    public let barCount: Int
    public let time: Double
    public let mode: WaveformMode
    public let audioLevel: Double?
    public let maxHeight: CGFloat
    public let minHeight: CGFloat
    public let barWidth: CGFloat

    public var body: some View {
        let height = barHeight
        let color = barColor

        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(height: height)
            .shadow(color: color.opacity(glowOpacity), radius: glowRadius, y: 0)
            .animation(.easeInOut(duration: 0.22), value: mode)
    }

    // MARK: - Height Calculation

    private var barHeight: CGFloat {
        let normalized = WaveformMetrics.normalizedLevel(
            mode: mode,
            audioLevel: audioLevel,
            time: time,
            index: index,
            barCount: barCount
        )
        return minHeight + (maxHeight - minHeight) * normalized
    }

    // MARK: - Color

    private var barColor: Color {
        switch mode {
        case .idle: Theme.idleColor
        case .processing: Theme.speakingColor
        case .listening: Theme.recordingColor
        case .speechDetected: Theme.recordingColor
        }
    }

    private var glowOpacity: Double {
        switch mode {
        case .idle: 0
        case .processing: 0.35
        case .listening: 0.25
        case .speechDetected: 0.45
        }
    }

    private var glowRadius: CGFloat {
        switch mode {
        case .idle: 0
        case .processing: 4
        case .listening: 3
        case .speechDetected: 5
        }
    }
}
