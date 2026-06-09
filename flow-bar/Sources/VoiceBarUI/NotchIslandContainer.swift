import SwiftUI

public struct NotchIslandContainer<Content: View>: View {
    private let contentSize: CGSize
    private let content: Content

    public init(contentSize: CGSize, @ViewBuilder content: () -> Content) {
        self.contentSize = contentSize
        self.content = content()
    }

    public var body: some View {
        let islandSize = NotchIslandGeometry.panelSize(for: contentSize)
        let contentRect = NotchIslandGeometry.contentRect(for: contentSize)

        ZStack(alignment: .bottom) {
            NotchIslandShape()
                .fill(Theme.pillBackground)
                .overlay {
                    NotchIslandShape()
                        .stroke(Theme.pillInnerEdge, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.18), radius: 9, x: 0, y: 3)
                .allowsHitTesting(false)

            content
                .frame(width: contentRect.width, height: contentRect.height)
                .position(x: contentRect.midX, y: islandSize.height - contentRect.midY)
        }
        .frame(width: islandSize.width, height: islandSize.height)
    }
}

public struct NotchIslandShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let notch = CGRect(
            x: rect.midX - (NotchIslandGeometry.notchWidth / 2),
            y: rect.minY,
            width: NotchIslandGeometry.notchWidth,
            height: NotchIslandGeometry.notchDepth
        )
        let radius: CGFloat = 18
        let notchRadius: CGFloat = 14
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: notch.minX - notchRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: notch.minX, y: rect.minY + notchRadius),
            control: CGPoint(x: notch.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: notch.minX, y: notch.maxY - notchRadius))
        path.addQuadCurve(
            to: CGPoint(x: notch.minX + notchRadius, y: notch.maxY),
            control: CGPoint(x: notch.minX, y: notch.maxY)
        )
        path.addLine(to: CGPoint(x: notch.maxX - notchRadius, y: notch.maxY))
        path.addQuadCurve(
            to: CGPoint(x: notch.maxX, y: notch.maxY - notchRadius),
            control: CGPoint(x: notch.maxX, y: notch.maxY)
        )
        path.addLine(to: CGPoint(x: notch.maxX, y: rect.minY + notchRadius))
        path.addQuadCurve(
            to: CGPoint(x: notch.maxX + notchRadius, y: rect.minY),
            control: CGPoint(x: notch.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
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
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}
