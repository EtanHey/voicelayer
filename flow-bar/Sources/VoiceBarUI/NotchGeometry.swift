// NotchGeometry.swift — v9 notch-conforming geometry.
//
// The v9 transform (Etan, 2026-06-10): the bar stops being a floating Capsule and
// becomes ONE black notch-conforming silhouette that hugs the camera island, and the
// panel "grows OUT of the notch" via reverse/inverted-radius shoulders with a
// black→glass gradient (mock: docs.local/design/notch-v9.html).
//
// Geometry is grounded in the notch-apps steal-list (2026-06-07):
//   S2 — closedWidth = screen.frame.width − auxTopLeft.width − auxTopRight.width + 4
//        closedHeight = safeAreaInsets.top   (nil fallback ≈ 185 / 32)
//   S3 — ONE morphing Shape with AnimatablePair(topRadius, bottomRadius); top corners
//        flare OUTWARD into the menu bar; bottom corners larger.
//
// This file is pure geometry (no AppKit pointer routing) so it unit-tests cleanly and
// carries zero forbidden synthetic-mouse symbols (see ForbiddenPointerAPIGateTests).

import CoreGraphics
import SwiftUI

// MARK: - Closed-notch metrics (S2)

/// Pure resolver for the closed notch rectangle, independent of NSScreen so it can be
/// unit-tested. Callers feed values pulled from `NSScreen` on the main actor.
public enum NotchMetrics {
    /// Seam overdraw (steal-list S2): the shell is drawn +4pt wider than the measured
    /// notch so the side seams against the hardware bezel are sealed.
    public static let seamOverdraw: CGFloat = 4

    /// Fallback width when a screen reports no auxiliary top areas (non-notched display
    /// or pre-measurement). 185pt is BoringNotch's documented fallback.
    public static let fallbackWidth: CGFloat = 185

    /// Fallback height when `safeAreaInsets.top` is 0 (flat display): the menu-bar height.
    public static let fallbackHeight: CGFloat = 32

    /// Closed notch width (steal-list S2 formula). When aux areas are unavailable
    /// (both zero) we fall back to `fallbackWidth` — a flat display has no notch to hug.
    public static func closedWidth(
        screenWidth: CGFloat,
        auxTopLeftWidth: CGFloat,
        auxTopRightWidth: CGFloat
    ) -> CGFloat {
        guard auxTopLeftWidth > 0 || auxTopRightWidth > 0 else { return fallbackWidth }
        let measured = screenWidth - auxTopLeftWidth - auxTopRightWidth + seamOverdraw
        return max(1, measured)
    }

    /// Closed notch height = `safeAreaInsets.top` exactly (Etan's "right at the height of
    /// the notch"). A non-positive inset (flat display) falls back to the menu-bar height.
    public static func closedHeight(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop > 0 ? safeAreaTop : fallbackHeight
    }

    /// A display is notched (use the island-blend presentation) only when it reports a
    /// positive top safe-area inset. Flat / external displays branch to the pill (S1).
    public static func isNotched(safeAreaTop: CGFloat) -> Bool {
        safeAreaTop > 0
    }
}

// MARK: - NotchShape (S3)

/// The closed/idle silhouette: a black field whose TOP corners flare OUTWARD into the
/// menu bar (concave quad-curves, like the hardware notch) and whose BOTTOM corners are
/// convex rounded. Driven by `AnimatablePair(topRadius, bottomRadius)` so every state
/// transition is a single silhouette morph (steal-list S3), never a window swap.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat = 6, bottomRadius: CGFloat = 14) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        // Clamp radii so a short/narrow rect never produces a self-intersecting path.
        let tr = max(0, min(topRadius, rect.width / 2))
        let br = max(0, min(bottomRadius, min(rect.width / 2, rect.height - tr)))

        // Start just outside the top-left, flaring INTO the menu bar with a concave
        // quad-curve (the "ear" of the notch), then straight down the left side, a
        // convex bottom-left, across the bottom, convex bottom-right, and a mirrored
        // concave flare back up into the menu bar on the right.
        path.move(to: CGPoint(x: rect.minX - tr, y: rect.minY))
        // top-left outward flare (concave): curve down-and-in to the left wall
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + tr),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        // left wall down to where the bottom fillet begins
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - br))
        // convex bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + br, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        // bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
        // convex bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        // right wall up to the top flare
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))
        // top-right outward flare (concave) back into the menu bar
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + tr, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - BarSilhouette (mode → v9 shape mapping, steal-list §3)

/// Which v9 silhouette a given voice mode renders. Pure mapping so the live BarView swap
/// (Capsule → NotchShape/FunnelPanelShape) is unit-tested against the steal-list §3 state
/// table without standing up SwiftUI.
public enum BarSilhouette {
    /// The two v9 silhouette kinds the live bar can take.
    public enum Kind: Equatable, Sendable {
        /// Compact black band hugging the camera island (idle / recording / transcribing /
        /// error / disconnected) — one `NotchShape` flush to the menu bar.
        case notchBand
        /// The funnel that "grows OUT of the notch" — `FunnelPanelShape` for speaking.
        case funnelPanel
    }

    /// steal-list §3 state table: speaking grows the funnel panel; every other state is the
    /// bare notch band hugging the island.
    public static func kind(for mode: VoiceMode) -> Kind {
        switch mode {
        case .speaking: .funnelPanel
        case .idle, .recording, .transcribing, .error, .disconnected: .notchBand
        }
    }

    /// The closed-island band shape (steal-list S3: top 6 / bottom 14).
    public static func notchBandShape(
        topRadius: CGFloat = NotchV9Style.closedTopRadius,
        bottomRadius: CGFloat = NotchV9Style.closedBottomRadius
    ) -> NotchShape {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
    }

    /// The funnel panel shape sized to a given notch-neck width.
    public static func funnelPanelShape(
        neckWidth: CGFloat,
        shoulderDrop: CGFloat = 22,
        bottomRadius: CGFloat = 18
    ) -> FunnelPanelShape {
        FunnelPanelShape(neckWidth: neckWidth, shoulderDrop: shoulderDrop, bottomRadius: bottomRadius)
    }
}

/// Type-erased v9 silhouette so the live BarView can drive `.clipShape`, `.contentShape`,
/// `.fill`, and `.stroke` from a SINGLE value per state — `NotchShape` for the band, the
/// `FunnelPanelShape` for the speaking funnel. (Plain `Shape`, not `InsettableShape`: the
/// band carries its own hairline via `.stroke`, never `.strokeBorder`.)
public struct BarShape: Shape {
    public var kind: BarSilhouette.Kind
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    public var neckWidth: CGFloat
    public var shoulderDrop: CGFloat

    public init(
        _ kind: BarSilhouette.Kind,
        topRadius: CGFloat = NotchV9Style.closedTopRadius,
        bottomRadius: CGFloat = NotchV9Style.closedBottomRadius,
        neckWidth: CGFloat = 128,
        shoulderDrop: CGFloat = 22
    ) {
        self.kind = kind
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.neckWidth = neckWidth
        self.shoulderDrop = shoulderDrop
    }

    public func path(in rect: CGRect) -> Path {
        switch kind {
        case .notchBand:
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: rect)
        case .funnelPanel:
            FunnelPanelShape(
                neckWidth: neckWidth,
                shoulderDrop: shoulderDrop,
                bottomRadius: bottomRadius
            ).path(in: rect)
        }
    }
}

// MARK: - FunnelPanelShape (v9 headline — "grows out of the notch")

/// The v9 panel silhouette. Unlike v8's square box, the panel's TOP narrows to the notch
/// neck and flares OUT with INVERSE (concave) shoulders — reading as one shape growing
/// from the notch. Mirrors the mock's `clip-path` funnel (notch-v9.html .dpanel.fun9 /
/// .gp.fun): a `neckWidth`-wide flat top, concave shoulders down to full width, convex
/// outer corners, rounded bottom.
///
/// Coordinates follow the mock: the neck is centered on the top edge; the shoulders use
/// `shoulderDrop` for both the vertical fall and the inset, giving the inverse-radius look.
public struct FunnelPanelShape: Shape {
    /// Width of the flat top neck (≈ closed notch width). Centered on the top edge.
    public var neckWidth: CGFloat
    /// Vertical distance the concave shoulders fall before the side walls begin.
    public var shoulderDrop: CGFloat
    /// Radius of the convex bottom corners.
    public var bottomRadius: CGFloat

    public init(neckWidth: CGFloat = 128, shoulderDrop: CGFloat = 22, bottomRadius: CGFloat = 18) {
        self.neckWidth = neckWidth
        self.shoulderDrop = shoulderDrop
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
        // Ported proportionally from the v9 mock clip-path (notch-v9.html .gp.fun):
        //   M(cx+nh,0) C(cx+nh,f)(cx+nh-cc,drop)(cx+nh-cc2,drop)  ← concave INVERSE shoulder
        //   L(out,drop) Q(0,drop)(0,drop+oc)  L(0,H-br) Q(0,H)(br,H)  L(W-br,H) Q(W,H)(W,H-br)
        //   L(W,drop+oc) Q(W,drop)(W-out,drop) L(cx+nh+cc2,drop) C…(cx-nh,0)  Z
        // The defining move is the CONCAVE (inverse-radius) shoulder: from the flat neck
        // the edge curves DOWN-and-OUT pulling INWARD first (control near the neck top),
        // so the panel reads as one shape funnelling out of the notch.
        var path = Path()
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let w = rect.width, h = rect.height
        let cx = rect.midX

        let drop = max(1, min(shoulderDrop, h * 0.45)) // shoulder vertical fall (≈22)
        let oc = max(0, min(drop, w * 0.06)) // outer top corner radius (≈18)
        let br = max(0, min(bottomRadius, min(w / 2, h - drop - oc)))
        let neck = max(0, min(neckWidth, w - 4 * drop)) // clamp neck so shoulders fit
        let nh = neck / 2

        // The concave shoulder horizontal run (from mock: 86→62 ≈ 24 ≈ drop+2).
        let shoulderRun = drop * 1.1

        // ---- trace clockwise from the neck's RIGHT end ----
        path.move(to: CGPoint(x: cx + nh, y: minY))
        // INVERSE/concave shoulder: cubic pulling inward at the neck then down-out.
        // control1 sits straight below the neck edge (vertical tangent at the top →
        // concave pocket); control2 reaches toward the shoulder foot.
        path.addCurve(
            to: CGPoint(x: cx + nh + shoulderRun, y: minY + drop),
            control1: CGPoint(x: cx + nh, y: minY + drop * 0.6),
            control2: CGPoint(x: cx + nh + shoulderRun * 0.55, y: minY + drop)
        )
        // flat run out to the outer top corner
        path.addLine(to: CGPoint(x: maxX - oc, y: minY + drop))
        // convex outer top-right corner
        path.addQuadCurve(
            to: CGPoint(x: maxX, y: minY + drop + oc),
            control: CGPoint(x: maxX, y: minY + drop)
        )
        // right wall
        path.addLine(to: CGPoint(x: maxX, y: maxY - br))
        // convex bottom-right
        path.addQuadCurve(to: CGPoint(x: maxX - br, y: maxY), control: CGPoint(x: maxX, y: maxY))
        // bottom edge
        path.addLine(to: CGPoint(x: minX + br, y: maxY))
        // convex bottom-left
        path.addQuadCurve(to: CGPoint(x: minX, y: maxY - br), control: CGPoint(x: minX, y: maxY))
        // left wall up
        path.addLine(to: CGPoint(x: minX, y: minY + drop + oc))
        // convex outer top-left corner
        path.addQuadCurve(
            to: CGPoint(x: minX + oc, y: minY + drop),
            control: CGPoint(x: minX, y: minY + drop)
        )
        // flat run in to the left shoulder foot
        path.addLine(to: CGPoint(x: cx - nh - shoulderRun, y: minY + drop))
        // INVERSE/concave shoulder back up to the neck (mirror)
        path.addCurve(
            to: CGPoint(x: cx - nh, y: minY),
            control1: CGPoint(x: cx - nh - shoulderRun * 0.55, y: minY + drop),
            control2: CGPoint(x: cx - nh, y: minY + drop * 0.6)
        )
        path.closeSubpath()
        return path
    }
}
