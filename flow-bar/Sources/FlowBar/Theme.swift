// Theme.swift — Design tokens for Voice Bar.
//
// Industrial-minimal aesthetic: solid dark pill, clean white text,
// bright state indicators. Dynamic width that breathes with content.

import SwiftUI

enum Theme {
    // MARK: - Colors

    static let speakingColor = Color(hex: 0x4A90D9) // Blue
    static let recordingColor = Color(hex: 0xE54D4D) // Red
    static let idleColor = Color(hex: 0xAEAEB2) // Light gray (legible on dark bg)
    static let transcribingColor = Color(hex: 0xE5A84D) // Yellow/orange
    static let errorColor = Color.red

    // MARK: - Pill background

    /// Solid dark background — works on any wallpaper, no vibrancy edge artifacts.
    static let pillBackground = Color.black.opacity(0.82)
    /// Subtle inner edge for depth — barely visible, adds polish.
    static let pillInnerEdge = Color.white.opacity(0.08)

    // MARK: - Pill dimensions

    /// Dynamic width: pill shrink-wraps content with minimum size.
    static let pillMinWidth: CGFloat = 100
    /// Panel needs to be large enough to never clip the pill.
    static let panelWidth: CGFloat = 500

    /// Seconds of idle before pill collapses.
    static let collapseDelay: TimeInterval = 5.0

    // MARK: - Position

    /// Horizontal position: 80% from left edge of screen (avoids covering Wispr Flow)
    static let horizontalOffset: CGFloat = 0.8
    /// Extra transparent clearance around pill so capsule corners aren't clipped by window edge.
    static let panelPadding: CGFloat = 4
    /// Vertical offset from bottom of visible area
    static let bottomPadding: CGFloat = 12

    // MARK: - Animation

    static let connectionTransition: Animation = .spring(duration: 0.3, bounce: 0.15)

    // MARK: - State-dependent color

    static func stateColor(for mode: VoiceMode) -> Color {
        switch mode {
        case .idle, .disconnected: idleColor
        case .speaking: speakingColor
        case .recording: recordingColor
        case .transcribing: transcribingColor
        case .error: errorColor
        }
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
