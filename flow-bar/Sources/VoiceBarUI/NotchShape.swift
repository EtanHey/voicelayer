import SwiftUI

public struct NotchShape: Shape {
    public var hasAttachedPanel: Bool

    public init(hasAttachedPanel: Bool = false) {
        self.hasAttachedPanel = hasAttachedPanel
    }

    /// v9 refinement #1 — when a panel is attached the bottom corners are softened by a
    /// few px (`Theme.notchAttachedCornerRadius`) instead of v8's hard square (0).
    public static func cornerRadius(hasAttachedPanel: Bool, rectHeight: CGFloat) -> CGFloat {
        let base = hasAttachedPanel ? Theme.notchAttachedCornerRadius : Theme.notchCornerRadius
        return min(base, rectHeight / 2)
    }

    public func path(in rect: CGRect) -> Path {
        let radius = NotchShape.cornerRadius(hasAttachedPanel: hasAttachedPanel, rectHeight: rect.height)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if radius > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
