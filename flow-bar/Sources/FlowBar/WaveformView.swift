// WaveformView.swift — Animated 7-bar waveform visualization.
//
// Three modes:
//   idle           — gentle breathing, barely visible
//   listening      — medium height, gentle swaying
//   speechDetected — active, lively movement
//
// Uses TimelineView at 60fps with golden-ratio phase offsets
// so bars never synchronize. Center bars are "louder" for a natural arc.

import SwiftUI

// MARK: - Waveform Mode (visual, not voice state)

enum WaveformMode: String, CaseIterable {
    case idle
    case listening
    case speechDetected
}

// MARK: - Waveform View

struct WaveformView: View {
    let mode: WaveformMode
    let audioLevel: Double?

    private let barCount = 7
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    init(mode: WaveformMode, audioLevel: Double? = nil) {
        self.mode = mode
        self.audioLevel = audioLevel
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        index: index,
                        barCount: barCount,
                        time: now,
                        mode: mode,
                        audioLevel: audioLevel,
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

// MARK: - Individual Bar

private struct WaveformBar: View {
    let index: Int
    let barCount: Int
    let time: Double
    let mode: WaveformMode
    let audioLevel: Double?
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let barWidth: CGFloat

    /// Golden-ratio-based offsets so bars never sync up
    private var phaseOffset: Double {
        let phi = 1.618033988749895
        return Double(index) * phi
    }

    /// Center bars are "louder" -- natural arc shape
    private var centerWeight: Double {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        return 1.0 - distance * 0.35
    }

    var body: some View {
        let height = barHeight
        let color = barColor

        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(height: height)
            .shadow(color: color.opacity(glowOpacity), radius: glowRadius, y: 0)
    }

    // MARK: - Height Calculation

    private var barHeight: CGFloat {
        let normalized: Double = switch mode {
        case .idle:
            idleLevel
        case .listening:
            listeningLevel
        case .speechDetected:
            if let level = audioLevel {
                audioLevelDriven(level)
            } else {
                speechSimulatedLevel
            }
        }

        let clamped = max(0, min(1, normalized))
        return minHeight + (maxHeight - minHeight) * clamped
    }

    // Idle: gentle breathing
    private var idleLevel: Double {
        let breath = sin(time * 1.2 + phaseOffset * 2.0) * 0.5 + 0.5
        let shimmer = sin(time * 3.7 + phaseOffset * 5.0) * 0.03
        return 0.05 + breath * 0.1 * centerWeight + shimmer
    }

    // Listening: medium sway
    private var listeningLevel: Double {
        let primary = sin(time * 2.0 + phaseOffset * 1.8) * 0.5 + 0.5
        let secondary = sin(time * 3.3 + phaseOffset * 3.1) * 0.15
        let drift = sin(time * 0.7 + phaseOffset) * 0.08
        return 0.25 + primary * 0.2 * centerWeight + secondary + drift
    }

    /// Speech detected: lively
    private var speechSimulatedLevel: Double {
        let fast = sin(time * 8.5 + phaseOffset * 2.3) * 0.25
        let medium = sin(time * 4.2 + phaseOffset * 3.7) * 0.2
        let slow = sin(time * 1.8 + phaseOffset * 1.1) * 0.15
        let pulse = sin(time * 6.1 + phaseOffset * 4.9) * 0.1
        let jitter = sin(time * 13.7 + phaseOffset * 7.3) * sin(time * 9.1 + phaseOffset * 5.2) * 0.12
        let base = 0.55 * centerWeight
        return base + fast + medium + slow + pulse + jitter
    }

    /// Audio-driven (v2)
    private func audioLevelDriven(_ level: Double) -> Double {
        let fast = sin(time * 7.0 + phaseOffset * 2.5) * 0.08
        let jitter = sin(time * 12.0 + phaseOffset * 6.0) * 0.05
        let envelope = level * centerWeight
        return 0.15 + envelope * 0.75 + fast + jitter
    }

    // MARK: - Color

    private var barColor: Color {
        switch mode {
        case .idle: Theme.idleColor
        case .listening: Theme.recordingColor
        case .speechDetected: Theme.recordingColor
        }
    }

    private var glowOpacity: Double {
        switch mode {
        case .idle: 0
        case .listening: 0.25
        case .speechDetected: 0.45
        }
    }

    private var glowRadius: CGFloat {
        switch mode {
        case .idle: 0
        case .listening: 3
        case .speechDetected: 5
        }
    }
}
