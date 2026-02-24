/// Theme.swift — Color constants, sizes, and animation parameters for Flow Bar.

import SwiftUI

enum Theme {
    // MARK: - Colors

    static let speakingColor = Color(hex: 0x4A90D9)   // Blue
    static let recordingColor = Color(hex: 0xE54D4D)   // Red
    static let idleColor = Color(hex: 0x8E8E93)        // System gray
    static let transcribingColor = Color(hex: 0xE5A84D) // Yellow/orange
    static let errorColor = Color.red

    // MARK: - Pill dimensions

    static let pillWidth: CGFloat = 280
    static let pillHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 22  // Half of height for capsule

    // MARK: - Position

    /// Horizontal position: 60% from left edge of screen
    static let horizontalOffset: CGFloat = 0.6
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
