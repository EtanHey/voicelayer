import SwiftUI

public struct NotchShape: Shape {
    public var hasAttachedPanel: Bool
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(hasAttachedPanel: Bool = false) {
        self.hasAttachedPanel = hasAttachedPanel
        topRadius = 0
        bottomRadius = Self.cornerRadius(hasAttachedPanel: hasAttachedPanel, rectHeight: .greatestFiniteMagnitude)
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    /// v9 refinement #1 — when a panel is attached the bottom corners are softened by a
    /// few px (`Theme.notchAttachedCornerRadius`) instead of v8's hard square (0).
    public static func cornerRadius(hasAttachedPanel: Bool, rectHeight: CGFloat) -> CGFloat {
        let base = hasAttachedPanel ? Theme.notchAttachedCornerRadius : Theme.notchCornerRadius
        return min(base, rectHeight / 2)
    }

    public func path(in rect: CGRect) -> Path {
        let top = min(max(0, topRadius), rect.height / 2)
        let bottom = min(max(0, bottomRadius), rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + top),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if bottom > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if top > 0 {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
