/// Theme.swift — Design tokens for Voice Bar.
///
/// Industrial-minimal aesthetic: solid dark pill, clean white text,
/// bright state indicators. Dynamic width that breathes with content.
///
/// AIDEV-NOTE: Design system documented in memory/voice-bar-design-system.md.
/// Update both when changing tokens here.

import SwiftUI

enum Theme {
    // MARK: - Colors

    static let speakingColor = Color(hex: 0x4A90D9)      // Blue
    static let recordingColor = Color(hex: 0xE54D4D)      // Red
    static let idleColor = Color(hex: 0xAEAEB2)           // Light gray (legible on dark bg)
    static let transcribingColor = Color(hex: 0xE5A84D)   // Yellow/orange
    static let errorColor = Color.red

    // MARK: - Pill background

    /// Solid dark background — works on any wallpaper, no vibrancy edge artifacts.
    static let pillBackground = Color.black.opacity(0.82)
    /// Subtle inner edge for depth — barely visible, adds polish.
    static let pillInnerEdge = Color.white.opacity(0.08)

    // MARK: - Pill dimensions

    /// Dynamic width: pill shrink-wraps content between min and max.
    static let pillMinWidth: CGFloat = 100
    static let pillMaxWidth: CGFloat = 300
    static let pillHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 22  // Half of height for capsule

    // MARK: - Position

    /// Horizontal position: 80% from left edge of screen (avoids covering Wispr Flow)
    static let horizontalOffset: CGFloat = 0.8
    /// Vertical offset from bottom of visible area
    static let bottomPadding: CGFloat = 12

    // MARK: - Animation

    static let stateTransition: Animation = .spring(duration: 0.4, bounce: 0.2)
    static let connectionTransition: Animation = .spring(duration: 0.3, bounce: 0.15)

    // MARK: - State-dependent color

    static func stateColor(for mode: VoiceMode) -> Color {
        switch mode {
        case .idle, .disconnected:  return idleColor
        case .speaking:             return speakingColor
        case .recording:            return recordingColor
        case .transcribing:         return transcribingColor
        case .error:                return errorColor
        }
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
