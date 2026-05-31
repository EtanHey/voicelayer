// Theme.swift — Design tokens for Voice Bar.
//
// Industrial-minimal aesthetic: solid dark pill, clean white text,
// bright state indicators. Dynamic width that breathes with content.

import SwiftUI

public enum Theme {
    // MARK: - Colors

    public static let speakingColor = Color(hex: 0x4A90D9) // Blue
    public static let recordingColor = Color(hex: 0xE54D4D) // Red
    public static let idleColor = Color(hex: 0xAEAEB2) // Light gray (legible on dark bg)
    public static let transcribingColor = Color(hex: 0xE5A84D) // Yellow/orange
    public static let errorColor = Color.red

    // MARK: - Pill background

    /// Solid dark background — works on any wallpaper, no vibrancy edge artifacts.
    public static let pillBackground = Color.black.opacity(0.82)
    /// Subtle inner edge for depth — barely visible, adds polish.
    public static let pillInnerEdge = Color.white.opacity(0.08)

    // MARK: - Pill dimensions

    /// Dynamic width: pill shrink-wraps content with minimum size.
    public static let pillMinWidth: CGFloat = 100
    public static let pillCompactWidth: CGFloat = 136
    public static let pillCompactHeight: CGFloat = 42
    public static let pillStatusMaxWidth: CGFloat = 160
    public static let pillTranscriptPreviewWidth: CGFloat = 330
    public static let pillTranscriptPreviewHeight: CGFloat = 70
    public static let pillQueueWidth: CGFloat = 300
    public static let pillActionButtonSize: CGFloat = 26
    public static let pillActionButtonSpacing: CGFloat = 2
    public static let pillSpeakingQueueWidth: CGFloat = 412
    /// Fixed panel envelope that keeps AppKit out of resize loops without
    /// leaving a large invisible draggable surface around the pill.
    public static let panelWidth: CGFloat = 420
    public static let panelHeight: CGFloat = 74

    public static func transcriptPreviewWidth(for text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let estimated = CGFloat(trimmed.count) * 6.2
        return min(pillTranscriptPreviewWidth, max(120, estimated))
    }

    public static func compactStatusWidth(for text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let estimated = CGFloat(trimmed.count) * 6.6
        return min(220, max(64, estimated))
    }

    public static func compactPillWidth(for statusText: String, accessoryButtonCount: Int = 0) -> CGFloat {
        let textWidth = compactStatusWidth(for: statusText)
        let safeButtonCount = max(0, accessoryButtonCount)
        let accessoryButtonWidth: CGFloat
        if safeButtonCount > 0 {
            accessoryButtonWidth =
                (CGFloat(safeButtonCount) * pillActionButtonSize) +
                (CGFloat(safeButtonCount - 1) * pillActionButtonSpacing)
        } else {
            accessoryButtonWidth = 0
        }
        let accessoryLeadingGap: CGFloat = safeButtonCount > 0 ? 8 : 0
        let compactChromeWidth: CGFloat = 68
        let minimumWidth: CGFloat = 190
        return min(
            panelWidth - (panelPadding * 2),
            max(minimumWidth, textWidth + compactChromeWidth + accessoryLeadingGap + accessoryButtonWidth)
        )
    }

    public static let hotkeyTransitionPillWidth: CGFloat = compactPillWidth(for: "Tap again to lock")

    public static func transcribingPillWidth(for statusText: String) -> CGFloat {
        let textWidth = compactStatusWidth(for: statusText)
        guard textWidth > 0 else { return 102 }
        return min(panelWidth - (panelPadding * 2), max(212, textWidth + 96))
    }

    public static func pillContentWidth(
        for mode: VoiceMode,
        statusText: String,
        idleAccessoryButtonCount: Int = 0,
        queueItemCount: Int = 0
    ) -> CGFloat {
        switch mode {
        case .recording:
            return 154
        case .transcribing:
            return transcribingPillWidth(for: statusText)
        case .speaking:
            return queueItemCount > 1 ? pillSpeakingQueueWidth : 340
        case .error:
            return 210
        case .idle, .disconnected:
            let statusWidth = compactPillWidth(
                for: statusText,
                accessoryButtonCount: mode == .idle ? idleAccessoryButtonCount : 0
            )
            return VoiceBarPresentation.isHotkeyTransitionStatus(statusText)
                ? max(statusWidth, hotkeyTransitionPillWidth)
                : statusWidth
        }
    }

    public static func transcriptPreviewPillWidth(for text: String) -> CGFloat {
        min(panelWidth - (panelPadding * 2), transcriptPreviewWidth(for: text) + 82)
    }
    /// Speaking mode keeps a fixed teleprompter viewport so long text scrolls
    /// inside the pill instead of stretching the capsule.
    public static let teleprompterViewportWidth: CGFloat = 280
    public static let teleprompterViewportHeight: CGFloat = 68
    public static let teleprompterWrapWidth: CGFloat = 272
    public static let teleprompterContentInset: CGFloat = 4

    /// Seconds of idle before pill collapses.
    public static let collapseDelay: TimeInterval = 5.0

    // MARK: - Position

    /// Horizontal position: centered like a small macOS island.
    public static let horizontalOffset: CGFloat = 0.5
    /// Extra transparent clearance around pill so capsule corners aren't clipped by window edge.
    public static let panelPadding: CGFloat = 4
    /// Vertical offset from top of visible area.
    public static let topPadding: CGFloat = 12

    // MARK: - Animation

    public static let connectionTransition: Animation = .smooth(duration: 0.28)
    public static let pillTransition: Animation = .smooth(duration: 0.34)
    /// Smooth crossfade for mode changes — avoids bouncy intermediate states.
    public static let modeTransition: Animation = .smooth(duration: 0.24)
    public static let queueProgressTransition: Animation = .easeOut(duration: 0.18)

    // MARK: - State-dependent color

    public static func stateColor(for mode: VoiceMode) -> Color {
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
