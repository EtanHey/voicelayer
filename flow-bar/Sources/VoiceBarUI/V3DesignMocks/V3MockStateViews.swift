// V3MockStateViews.swift — static state mocks for the notched island (MOCK-FIRST).
//
// Pure visual artifacts: no timers, no sockets, no state machine. Frozen
// values stand in for live data (RMS bars, timer). Codex renders + captures;
// wiring happens only after Etan approves the look.
//
// Vertical contract (rubric 6b / Etan R3 fix #4): every state is TOP-FLUSH —
// the shape's top edge sits at y=0 of the screen, only the bottom edge moves
// between states. Renders must place these views at the exact top of the
// built-in display, horizontally centered on the notch.

import SwiftUI

// MARK: - Idle — the bare silhouette (steal S7: zero chrome)

/// Idle is pixel-identical to the hardware island: pure #000, no stroke, no
/// shadow, no content. You cannot tell the app is running. (refs/f_01.png)
public struct V3MockIdleIsland: View {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat = V3Theme.previewNotchWidth,
                height: CGFloat = V3Theme.previewNotchHeight) {
        self.width = width
        self.height = height
    }

    public var body: some View {
        V3NotchShape(
            topCornerRadius: V3Theme.radiiClosed.top,
            bottomCornerRadius: V3Theme.radiiClosed.bottom
        )
        .fill(V3Theme.islandBlack)
        .frame(width: width, height: height)
    }
}

// MARK: - Recording — wings layout (steal S6: content in the ears)

/// Recording: the island widens to ~1.35x notch. Mic dot + timer on the LEFT
/// wing, frozen RMS bars on the RIGHT wing, and a black spacer the width of
/// the camera region between them — NOTHING renders over the cutout.
/// Structure target: visually confusable with refs/f_05.png.
public struct V3MockRecordingIsland: View {
    public var notchWidth: CGFloat
    public var height: CGFloat
    /// Frozen mock RMS heights (real audio_level drives these at wiring time).
    private let barHeights: [CGFloat] = [6, 11, 14, 9, 12]

    public init(notchWidth: CGFloat = V3Theme.previewNotchWidth,
                height: CGFloat = V3Theme.previewNotchHeight) {
        self.notchWidth = notchWidth
        self.height = height
    }

    public var body: some View {
        let totalWidth = notchWidth * V3Theme.recordingWidthRatio
        HStack(spacing: 0) {
            // Left wing: mic-live dot + elapsed time (monospaced — S15 .numericText at wiring).
            HStack(spacing: 5) {
                Circle()
                    .fill(V3Theme.micLiveDot)
                    .frame(width: 7, height: 7)
                Text("0:42")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(V3Theme.wingText)
            }
            .frame(maxWidth: .infinity)

            // Camera region: hardware owns it. (S6 spacer = closedWidth − 20)
            Color.clear
                .frame(width: V3Theme.cameraSpacerWidth(closedWidth: notchWidth))

            // Right wing: RMS bars in a FIXED slot (S9 — frozen on silence).
            HStack(spacing: V3Theme.barSpacing) {
                ForEach(barHeights.indices, id: \.self) { i in
                    Capsule()
                        .fill(V3Theme.barColor)
                        .frame(width: V3Theme.barWidth, height: barHeights[i])
                }
            }
            .frame(width: V3Theme.barSlotWidth)
            .frame(maxWidth: .infinity)
        }
        .frame(width: totalWidth, height: height)
        .background(
            V3NotchShape(
                topCornerRadius: V3Theme.radiiClosed.top,
                bottomCornerRadius: V3Theme.radiiClosed.bottom
            )
            .fill(V3Theme.islandBlack)
        )
    }
}

// MARK: - Flat-display pill (S1 per-display switch — never a fake notch, A1)

/// External/no-notch displays get a REAL pill: full strip height, system
/// material, centered in the strip. The notched silhouette never appears here.
public struct V3MockFlatRecordingPill: View {
    public var stripHeight: CGFloat
    private let barHeights: [CGFloat] = [6, 11, 14, 9, 12]

    public init(stripHeight: CGFloat = 24) {
        self.stripHeight = stripHeight
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(V3Theme.micLiveDot)
                .frame(width: 7, height: 7)
            Text("0:42")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
            HStack(spacing: V3Theme.barSpacing) {
                ForEach(barHeights.indices, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(0.85))
                        .frame(width: V3Theme.barWidth, height: min(barHeights[i], stripHeight - 10))
                }
            }
            .frame(width: V3Theme.barSlotWidth)
        }
        .padding(.horizontal, 12)
        .frame(height: stripHeight)
        .background(V3Theme.flatPillMaterial, in: Capsule())
    }
}

// MARK: - Previews

#Preview("Idle (notched)") {
    V3MockIdleIsland()
        .padding(20)
        .background(Color(red: 0.25, green: 0.2, blue: 0.5))
}

#Preview("Recording (notched, wings)") {
    V3MockRecordingIsland()
        .padding(20)
        .background(Color(red: 0.25, green: 0.2, blue: 0.5))
}

#Preview("Recording (flat pill)") {
    V3MockFlatRecordingPill()
        .padding(20)
        .background(Color(red: 0.25, green: 0.2, blue: 0.5))
}
