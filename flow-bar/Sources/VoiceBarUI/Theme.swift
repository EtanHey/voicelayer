// Theme.swift — Design tokens for Voice Bar.
//
// Industrial-minimal aesthetic: solid dark pill, clean white text,
// bright state indicators. Dynamic width that breathes with content.

import AppKit
import SwiftUI

public struct VoiceBarPillMetrics: Equatable {
    public var width: CGFloat
    public var contentWidth: CGFloat
    public var horizontalPadding: CGFloat
    public var contentSpacing: CGFloat
}

public enum Theme {
    // MARK: - Colors

    public static let speakingColor = Color(hex: 0x4A90D9) // Blue
    public static let recordingColor = Color(hex: 0xE54D4D) // Red
    public static let idleColor = Color(hex: 0xAEAEB2) // Light gray (legible on dark bg)
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
    public static let pillWaveformWidth: CGFloat = 46
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
        let accessoryButtonWidth: CGFloat = if safeButtonCount > 0 {
            (CGFloat(safeButtonCount) * pillActionButtonSize) +
                (CGFloat(safeButtonCount - 1) * pillActionButtonSpacing)
        } else {
            0
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

    public static func intrinsicPillStatusWidth(for text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let measured = (trimmed as NSString).size(withAttributes: [.font: font]).width
        return min(pillStatusMaxWidth, ceil(measured))
    }

    public static func transcribingPillWidth(for statusText: String) -> CGFloat {
        pillMetrics(for: .transcribing, statusText: statusText).width
    }

    public static func pillMetrics(
        for mode: VoiceMode,
        statusText: String,
        idleAccessoryButtonCount: Int = 0,
        queueItemCount: Int = 0,
        showsRecordingHold: Bool = false
    ) -> VoiceBarPillMetrics {
        let defaultHorizontalPadding: CGFloat = 14
        let compactHorizontalPadding: CGFloat = 10
        let contentSpacing: CGFloat = 8
        let maximumWidth = panelWidth - (panelPadding * 2)

        switch mode {
        case .recording:
            let actionButtonCount = showsRecordingHold ? 3 : 2
            let actionButtonsWidth = pillActionButtonsWidth(count: actionButtonCount)
            let contentWidth = 8 + pillWaveformWidth + actionButtonsWidth + (contentSpacing * 2)
            return VoiceBarPillMetrics(
                width: contentWidth + (compactHorizontalPadding * 2),
                contentWidth: contentWidth,
                horizontalPadding: compactHorizontalPadding,
                contentSpacing: contentSpacing
            )
        case .transcribing:
            let statusWidth = intrinsicPillStatusWidth(for: statusText)
            let statusSegmentWidth = statusWidth > 0 ? 8 + statusWidth : 0
            let naturalContentWidth = pillWaveformWidth + statusSegmentWidth +
                contentSpacing + pillActionButtonSize
            let clampedContentWidth = min(
                naturalContentWidth,
                maximumWidth - (compactHorizontalPadding * 2)
            )
            let width = max(
                pillCompactWidth,
                clampedContentWidth + (compactHorizontalPadding * 2)
            )
            return VoiceBarPillMetrics(
                width: width,
                contentWidth: width - (compactHorizontalPadding * 2),
                horizontalPadding: compactHorizontalPadding,
                contentSpacing: contentSpacing
            )
        case .speaking:
            return fixedPillMetrics(
                width: pillSpeakingQueueWidth,
                horizontalPadding: defaultHorizontalPadding,
                contentSpacing: contentSpacing
            )
        case .error:
            return fixedPillMetrics(
                width: 210,
                horizontalPadding: defaultHorizontalPadding,
                contentSpacing: contentSpacing
            )
        case .idle, .disconnected:
            let statusWidth = compactPillWidth(
                for: statusText,
                accessoryButtonCount: mode == .idle ? idleAccessoryButtonCount : 0
            )
            let width = VoiceBarPresentation.isHotkeyTransitionStatus(statusText)
                ? max(statusWidth, hotkeyTransitionPillWidth)
                : statusWidth
            return fixedPillMetrics(
                width: width,
                horizontalPadding: defaultHorizontalPadding,
                contentSpacing: contentSpacing
            )
        }
    }

    public static func pillContentWidth(
        for mode: VoiceMode,
        statusText: String,
        idleAccessoryButtonCount: Int = 0,
        queueItemCount: Int = 0,
        showsRecordingHold: Bool = false
    ) -> CGFloat {
        pillMetrics(
            for: mode,
            statusText: statusText,
            idleAccessoryButtonCount: idleAccessoryButtonCount,
            queueItemCount: queueItemCount,
            showsRecordingHold: showsRecordingHold
        ).width
    }

    private static func pillActionButtonsWidth(count: Int) -> CGFloat {
        let safeCount = max(0, count)
        guard safeCount > 0 else { return 0 }
        return (CGFloat(safeCount) * pillActionButtonSize) +
            (CGFloat(safeCount - 1) * pillActionButtonSpacing)
    }

    private static func fixedPillMetrics(
        width: CGFloat,
        horizontalPadding: CGFloat,
        contentSpacing: CGFloat
    ) -> VoiceBarPillMetrics {
        VoiceBarPillMetrics(
            width: width,
            contentWidth: max(0, width - (horizontalPadding * 2)),
            horizontalPadding: horizontalPadding,
            contentSpacing: contentSpacing
        )
    }

    public static func transcriptPreviewPillWidth(for text: String) -> CGFloat {
        min(panelWidth - (panelPadding * 2), transcriptPreviewWidth(for: text) + 82)
    }

    /// Speaking mode keeps a fixed teleprompter viewport so long text scrolls
    /// inside the pill instead of stretching the capsule.
    public static let teleprompterViewportWidth: CGFloat = 254
    public static let teleprompterViewportHeight: CGFloat = 78
    public static let teleprompterWrapWidth: CGFloat = 246
    public static let teleprompterContentInset: CGFloat = 4

    public static let speakingTeleprompterChromeWidth: CGFloat =
        14 + 14 + 6 + 46 + (pillActionButtonSize * 2) + pillActionButtonSpacing + (8 * 3)
    public static let speakingTeleprompterAvailableWidth: CGFloat =
        pillSpeakingQueueWidth - speakingTeleprompterChromeWidth

    /// Live speaking has two trailing controls; idle readback can have eye,
    /// close, history, vocabulary, and replay. Expand only the readback pill so
    /// its complete accessory row remains inside the capsule and hit region.
    public static func teleprompterPillWidth(
        for mode: VoiceMode,
        accessoryButtonCount: Int = 0
    ) -> CGFloat {
        guard mode == .idle else { return pillSpeakingQueueWidth }
        let safeButtonCount = max(0, accessoryButtonCount)
        let accessoryWidth: CGFloat = if safeButtonCount > 0 {
            (CGFloat(safeButtonCount) * pillActionButtonSize) +
                (CGFloat(safeButtonCount - 1) * pillActionButtonSpacing)
        } else {
            0
        }
        let horizontalPadding: CGFloat = 28
        let leadingIndicatorWidth: CGFloat = 6
        let hStackGaps: CGFloat = safeButtonCount > 0 ? 16 : 8
        return max(
            pillSpeakingQueueWidth,
            horizontalPadding + leadingIndicatorWidth + hStackGaps +
                teleprompterViewportWidth + accessoryWidth
        )
    }

    /// Seconds of idle before pill collapses.
    public static let collapseDelay: TimeInterval = 5.0

    // MARK: - Position

    /// Horizontal position: centered like a small macOS island.
    public static let horizontalOffset: CGFloat = 0.5
    /// Extra transparent clearance around pill so capsule corners aren't clipped by window edge.
    public static let panelPadding: CGFloat = 4
    /// Vertical offset from top of visible area.
    public static let topPadding: CGFloat = 12
    /// Overlap above the usable desktop so the existing pill tucks behind the menu-bar notch.
    public static let topAnchorNotchOverlap: CGFloat = 22

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
        // Transcribing intentionally stays blue to match speaking chrome.
        case .transcribing: speakingColor
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
