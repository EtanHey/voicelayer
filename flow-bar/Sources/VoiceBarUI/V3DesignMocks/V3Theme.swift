// V3Theme.swift — VoiceBar v3 design tokens (FUNCTIONAL-MOCK phase).
//
// Authored by Claude-V3-DESIGN. Constants trace to the notch-apps steal-list
// (docs.local/research/2026-06-07-notch-apps-steal-list.md) — steal numbers
// cited inline so reviews can verify against the source.
//
// AIDEV-NOTE: v3 tokens are intentionally separate from Theme.swift — the
// resident pill keeps its tokens until Etan approves the v3 look.

import AppKit
import SwiftUI

public enum V3Theme {
    // MARK: - Notch geometry (steal S2 — boring.notch sizing formula)

    /// Width of the closed island: hardware notch width + 4pt overdraw so the
    /// shape seals over the cutout edges with no seam. (S2)
    public static func closedNotchWidth(for screen: NSScreen?) -> CGFloat {
        guard
            let screen,
            let left = screen.auxiliaryTopLeftArea?.width,
            let right = screen.auxiliaryTopRightArea?.width
        else { return previewNotchWidth }
        return screen.frame.width - left - right + 4
    }

    /// FULL height of the strip (Etan R3 base geometry): the real notch depth
    /// on notched displays, the menu-bar height on flat ones. (S2/S11)
    public static func stripHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return previewNotchHeight }
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    /// Preview fallbacks (no NSScreen in SwiftUI previews / gallery renders).
    public static let previewNotchWidth: CGFloat = 200
    public static let previewNotchHeight: CGFloat = 38

    /// Recording state width multiplier — Etan R3 "narrower": NotchNook's live
    /// activity measures ~1.4–1.5x notch; we sit at the tight end. (S6/S10)
    public static let recordingWidthRatio: CGFloat = 1.35

    // MARK: - Corner radii ladder (steal S3 — animatable silhouette morph)

    /// (top, bottom) radii per tier. Top corners flare OUTWARD into the bar
    /// (see V3NotchShape) — the signature hardware-island geometry.
    public static let radiiClosed: (top: CGFloat, bottom: CGFloat) = (6, 14)
    public static let radiiPeek: (top: CGFloat, bottom: CGFloat) = (13, 19)
    public static let radiiExpanded: (top: CGFloat, bottom: CGFloat) = (19, 24)

    // MARK: - Materials (steal S5 — unanimous across all six notch apps)

    /// Inside the notch footprint: opaque #000, NEVER translucent (A3 —
    /// translucency reveals the hardware boundary and kills the blend).
    public static let islandBlack = Color.black
    /// Flat-display pill: system material (ladder tier 2; tier-1 .glassEffect
    /// arrives at wiring time on macOS 26+).
    public static let flatPillMaterial: Material = .ultraThinMaterial

    // MARK: - Content accents (restraint: neutral shell, accent in content)

    public static let micLiveDot = Color(red: 1.0, green: 0.27, blue: 0.23) // iOS mic-indicator red-orange
    public static let wingText = Color.white.opacity(0.92)
    public static let wingTextSecondary = Color.white.opacity(0.55)
    public static let barColor = Color.white.opacity(0.9)

    // MARK: - Wings layout (steal S6 — InlineHUD flank pattern)

    /// Black spacer over the camera = the FULL closed island width (notch
    /// + 4pt overdraw). NOTHING renders inside this region — the hardware
    /// owns it. (voicebarUI-LEAD R4 fix: boring.notch's −20 put wing content
    /// up to 10pt INSIDE the notch rect at our widths — the exact
    /// "seconds behind the camera" defect Etan rejected.)
    public static func cameraSpacerWidth(closedWidth: CGFloat) -> CGFloat {
        closedWidth
    }

    /// Fixed wing width per side (S10 content-driven: sized to dot+timer /
    /// bar slot + breathing room). Recording width = closedWidth + 2 wings
    /// ≈ 1.47x the notch — inside NotchNook's measured 1.4–1.5x live band.
    public static let wingWidth: CGFloat = 44

    /// RMS bars live in a FIXED slot so the shell never jitters (S9/A13).
    public static let barSlotWidth: CGFloat = 34
    public static let barWidth: CGFloat = 2
    public static let barSpacing: CGFloat = 2
    public static let barMaxHeight: CGFloat = 14

    // MARK: - Transcript menu (Etan feature spec + Alcove QuickPeek tiers)

    public static let menuWidth: CGFloat = 380
    /// Natural height of the open menu's content region (drives the pull
    /// morph; the shell adds stripHeight above it).
    public static let menuContentHeight: CGFloat = 330
    /// Release past this fraction of the pull commits to open (grab-down spec).
    public static let menuOpenThreshold: CGFloat = 0.4
    public static let menuRowVPad: CGFloat = 9
    public static let menuRowHPad: CGFloat = 14
    /// Dark content surface INSIDE the shell — glass/black is shell-only.
    public static let menuContentSurface = Color(red: 0.08, green: 0.08, blue: 0.09)

    // MARK: - Springs (steal S4)

    /// Open: slight overshoot is the category brand signature.
    public static let springOpen = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Close: critically damped — it "seals" shut. Overshoot on close = broken (A4).
    public static let springClose = Animation.spring(response: 0.45, dampingFraction: 1.0)
    public static let springInteractive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8)

    // MARK: - Helpers

    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * min(max(t, 0), 1)
    }
}
