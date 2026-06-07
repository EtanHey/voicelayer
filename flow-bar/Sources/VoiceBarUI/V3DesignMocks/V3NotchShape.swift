// V3NotchShape.swift — the island silhouette (MOCK-FIRST phase).
//
// Re-derived from the DynamicNotchKit pattern (MIT, MrKai77) — steal S3.
// The defining feature vs a rounded rect: the TOP corners quad-curve
// OUTWARD, so the shape is widest at the very top edge and melts into the
// menu bar exactly like the hardware camera island. A standard capsule
// (inward corners all around) reads "sticker on the screen"; this reads
// "part of the machine".
//
// Radii are AnimatablePair so every state change is a silhouette MORPH of
// one shape (S3/S14 — never show/hide separate windows).

import SwiftUI

public struct V3NotchShape: Shape {
    public var topCornerRadius: CGFloat
    public var bottomCornerRadius: CGFloat

    public init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        // Start at the top-left EXTREME — the shape owns the full top edge.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left corner flares OUTWARD: curve from the top edge down-and-in.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        // Left side down to the bottom-left curve.
        p.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        // Bottom-left corner: conventional inward round.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        // Bottom-right corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        // Right side up.
        p.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        // Top-right corner flares OUTWARD to the top edge extreme.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

#Preview("NotchShape tiers") {
    VStack(spacing: 12) {
        V3NotchShape(topCornerRadius: V3Theme.radiiClosed.top, bottomCornerRadius: V3Theme.radiiClosed.bottom)
            .frame(width: 200, height: 38)
        V3NotchShape(topCornerRadius: V3Theme.radiiPeek.top, bottomCornerRadius: V3Theme.radiiPeek.bottom)
            .frame(width: 270, height: 70)
        V3NotchShape(topCornerRadius: V3Theme.radiiExpanded.top, bottomCornerRadius: V3Theme.radiiExpanded.bottom)
            .frame(width: 380, height: 190)
    }
    .padding(24)
    .background(Color(red: 0.25, green: 0.2, blue: 0.5))
}
