import SwiftUI

public struct NotchShape: Shape {
    public var sideRadius: CGFloat

    public init(sideRadius: CGFloat = Theme.notchSideRadius) {
        self.sideRadius = sideRadius
    }

    public func path(in rect: CGRect) -> Path {
        let radius = min(max(0, sideRadius), rect.width / 2, rect.height)
        let bodyMinX = rect.minX + radius
        let bodyMaxX = rect.maxX - radius
        let lowerCurveMinY = rect.maxY - radius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: lowerCurveMinY))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: lowerCurveMinY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
