import CoreGraphics
import SwiftUI

public enum VoiceBarNotchSide: Equatable, Sendable {
    case leading
    case trailing
}

public struct VoiceBarNotchShapeLayout: Equatable {
    public let geometry: VoiceBarNotchGeometry
    public let inverseJoinRadius: CGFloat
    public let lowerCornerRadius: CGFloat

    public init(
        geometry: VoiceBarNotchGeometry,
        inverseJoinRadius: CGFloat = VoiceBarNotchContract.material.inverseJoinRadius,
        lowerCornerRadius: CGFloat = 18
    ) {
        self.geometry = geometry
        self.inverseJoinRadius = inverseJoinRadius
        self.lowerCornerRadius = lowerCornerRadius
    }

    public var totalSize: CGSize {
        CGSize(width: geometry.totalWidth, height: geometry.totalHeight)
    }

    public var coreRect: CGRect {
        CGRect(
            x: geometry.coreOriginX,
            y: 0,
            width: geometry.coreWidth,
            height: geometry.topHeight
        )
    }

    public var leadingWingRect: CGRect {
        CGRect(
            x: geometry.topOriginX,
            y: 0,
            width: geometry.leadingWingWidth,
            height: geometry.topHeight
        )
    }

    public var trailingWingRect: CGRect {
        CGRect(
            x: coreRect.maxX,
            y: 0,
            width: geometry.trailingWingWidth,
            height: geometry.topHeight
        )
    }

    public var bodyRect: CGRect {
        guard geometry.lowerSurfaceHeight > 0 else { return .zero }
        return CGRect(
            x: geometry.bodyOriginX,
            y: geometry.topHeight,
            width: geometry.bodyWidth,
            height: geometry.lowerSurfaceHeight
        )
    }
}

public struct VoiceBarNotchWingShape: Shape {
    public let side: VoiceBarNotchSide
    public var outerCornerRadius: CGFloat

    public init(side: VoiceBarNotchSide, outerCornerRadius: CGFloat = 11) {
        self.side = side
        self.outerCornerRadius = outerCornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let radius = min(outerCornerRadius, rect.width, rect.height)
        var path = Path()

        switch side {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.closeSubpath()
        return path
    }
}

/// One material mask containing the two top wings and, when present, the lower body.
/// The physical camera housing is intentionally absent from the path.
public struct VoiceBarNotchContinuousShape: Shape {
    public let geometry: VoiceBarNotchGeometry

    public init(geometry: VoiceBarNotchGeometry) {
        self.geometry = geometry
    }

    public func path(in rect: CGRect) -> Path {
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        guard layout.totalSize.width > 0,
              layout.totalSize.height > 0,
              rect.width > 0,
              rect.height > 0
        else {
            return Path()
        }

        var path = Path()
        if layout.leadingWingRect.width > 0 {
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .leading,
                    outerCornerRadius: layout.inverseJoinRadius
                ).path(in: layout.leadingWingRect)
            )
        }
        if layout.trailingWingRect.width > 0 {
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .trailing,
                    outerCornerRadius: layout.inverseJoinRadius
                ).path(in: layout.trailingWingRect)
            )
        }
        if !layout.bodyRect.isEmpty {
            path.addPath(lowerBodyPath(layout: layout))
        }

        let transform = CGAffineTransform(
            a: rect.width / layout.totalSize.width,
            b: 0,
            c: 0,
            d: rect.height / layout.totalSize.height,
            tx: rect.minX,
            ty: rect.minY
        )
        return path.applying(transform)
    }

    private func lowerBodyPath(layout: VoiceBarNotchShapeLayout) -> Path {
        let rect = layout.bodyRect
        let topRadius = min(layout.inverseJoinRadius, rect.width / 2, rect.height / 2)
        let lowerRadius = min(layout.lowerCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: layout.leadingWingRect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - lowerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + lowerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - lowerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - lowerRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: layout.trailingWingRect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
