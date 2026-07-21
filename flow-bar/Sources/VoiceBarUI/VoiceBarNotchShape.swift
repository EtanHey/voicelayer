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

/// Software pixels around the physical camera housing keep the same rounded
/// lower silhouette when glass wings appear.
public struct VoiceBarNotchHardwareCoreShape: Shape {
    public var lowerCornerRadius: CGFloat

    public init(lowerCornerRadius: CGFloat) {
        self.lowerCornerRadius = lowerCornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        let radius = min(lowerCornerRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
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
        path.closeSubpath()
        return path
    }
}

/// One material mask containing the two top wings and, when present, the lower body.
/// The physical camera housing is intentionally absent from the path.
public struct VoiceBarNotchGeometryAnimatableData: VectorArithmetic, Sendable {
    public var coreWidth: CGFloat
    public var topHeight: CGFloat
    public var leadingWingWidth: CGFloat
    public var trailingWingWidth: CGFloat
    public var bodyLeadingExtent: CGFloat
    public var bodyTrailingExtent: CGFloat
    public var lowerSurfaceHeight: CGFloat

    public init(geometry: VoiceBarNotchGeometry) {
        coreWidth = geometry.coreWidth
        topHeight = geometry.topHeight
        leadingWingWidth = geometry.leadingWingWidth
        trailingWingWidth = geometry.trailingWingWidth
        bodyLeadingExtent = geometry.bodyLeadingExtent
        bodyTrailingExtent = geometry.bodyTrailingExtent
        lowerSurfaceHeight = geometry.lowerSurfaceHeight
    }

    public static let zero = VoiceBarNotchGeometryAnimatableData(
        geometry: VoiceBarNotchGeometry(
            coreWidth: 0,
            topHeight: 0,
            leadingWingWidth: 0,
            trailingWingWidth: 0,
            bodyLeadingExtent: 0,
            bodyTrailingExtent: 0,
            lowerSurfaceHeight: 0
        )
    )

    public static func + (
        lhs: VoiceBarNotchGeometryAnimatableData,
        rhs: VoiceBarNotchGeometryAnimatableData
    ) -> VoiceBarNotchGeometryAnimatableData {
        VoiceBarNotchGeometryAnimatableData(
            geometry: VoiceBarNotchGeometry(
                coreWidth: lhs.coreWidth + rhs.coreWidth,
                topHeight: lhs.topHeight + rhs.topHeight,
                leadingWingWidth: lhs.leadingWingWidth + rhs.leadingWingWidth,
                trailingWingWidth: lhs.trailingWingWidth + rhs.trailingWingWidth,
                bodyLeadingExtent: lhs.bodyLeadingExtent + rhs.bodyLeadingExtent,
                bodyTrailingExtent: lhs.bodyTrailingExtent + rhs.bodyTrailingExtent,
                lowerSurfaceHeight: lhs.lowerSurfaceHeight + rhs.lowerSurfaceHeight
            )
        )
    }

    public static func - (
        lhs: VoiceBarNotchGeometryAnimatableData,
        rhs: VoiceBarNotchGeometryAnimatableData
    ) -> VoiceBarNotchGeometryAnimatableData {
        VoiceBarNotchGeometryAnimatableData(
            geometry: VoiceBarNotchGeometry(
                coreWidth: lhs.coreWidth - rhs.coreWidth,
                topHeight: lhs.topHeight - rhs.topHeight,
                leadingWingWidth: lhs.leadingWingWidth - rhs.leadingWingWidth,
                trailingWingWidth: lhs.trailingWingWidth - rhs.trailingWingWidth,
                bodyLeadingExtent: lhs.bodyLeadingExtent - rhs.bodyLeadingExtent,
                bodyTrailingExtent: lhs.bodyTrailingExtent - rhs.bodyTrailingExtent,
                lowerSurfaceHeight: lhs.lowerSurfaceHeight - rhs.lowerSurfaceHeight
            )
        )
    }

    public mutating func scale(by rhs: Double) {
        coreWidth *= rhs
        topHeight *= rhs
        leadingWingWidth *= rhs
        trailingWingWidth *= rhs
        bodyLeadingExtent *= rhs
        bodyTrailingExtent *= rhs
        lowerSurfaceHeight *= rhs
    }

    public var magnitudeSquared: Double {
        Double(
            coreWidth * coreWidth +
                topHeight * topHeight +
                leadingWingWidth * leadingWingWidth +
                trailingWingWidth * trailingWingWidth +
                bodyLeadingExtent * bodyLeadingExtent +
                bodyTrailingExtent * bodyTrailingExtent +
                lowerSurfaceHeight * lowerSurfaceHeight
        )
    }

    public var geometry: VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: coreWidth,
            topHeight: topHeight,
            leadingWingWidth: leadingWingWidth,
            trailingWingWidth: trailingWingWidth,
            bodyLeadingExtent: bodyLeadingExtent,
            bodyTrailingExtent: bodyTrailingExtent,
            lowerSurfaceHeight: lowerSurfaceHeight
        )
    }
}

public struct VoiceBarNotchContinuousShape: Shape {
    public var geometry: VoiceBarNotchGeometry
    public var compactOuterCornerRadius: CGFloat

    public init(
        geometry: VoiceBarNotchGeometry,
        compactOuterCornerRadius: CGFloat = 11
    ) {
        self.geometry = geometry
        self.compactOuterCornerRadius = compactOuterCornerRadius
    }

    public var animatableData: VoiceBarNotchGeometryAnimatableData {
        get { VoiceBarNotchGeometryAnimatableData(geometry: geometry) }
        set { geometry = newValue.geometry }
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

        let path = if layout.bodyRect.isEmpty {
            compactPath(layout: layout)
        } else {
            continuousBodyPath(layout: layout)
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

    private func compactPath(layout: VoiceBarNotchShapeLayout) -> Path {
        var path = Path()
        if layout.leadingWingRect.width > 0 {
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .leading,
                    outerCornerRadius: compactOuterCornerRadius
                )
                .path(in: layout.leadingWingRect)
            )
        }
        if layout.trailingWingRect.width > 0 {
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .trailing,
                    outerCornerRadius: compactOuterCornerRadius
                )
                .path(in: layout.trailingWingRect)
            )
        }
        return path
    }

    private func continuousBodyPath(layout: VoiceBarNotchShapeLayout) -> Path {
        let body = layout.bodyRect
        let leadingWing = layout.leadingWingRect
        let trailingWing = layout.trailingWingRect
        let core = layout.coreRect
        let shoulderRadius = min(
            layout.inverseJoinRadius,
            leadingWing.width,
            trailingWing.width,
            layout.geometry.topHeight
        )
        let lowerRadius = min(
            layout.lowerCornerRadius,
            body.width / 2,
            body.height / 2
        )
        var path = Path()

        path.move(to: CGPoint(x: core.minX, y: 0))
        path.addLine(to: CGPoint(x: leadingWing.minX, y: 0))
        path.addLine(to: CGPoint(x: leadingWing.minX, y: body.minY - shoulderRadius))
        path.addQuadCurve(
            to: CGPoint(x: leadingWing.minX - shoulderRadius, y: body.minY),
            control: CGPoint(x: leadingWing.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX + shoulderRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.minY + shoulderRadius),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - lowerRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + lowerRadius, y: body.maxY),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX - lowerRadius, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.maxY - lowerRadius),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + shoulderRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - shoulderRadius, y: body.minY),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: trailingWing.maxX + shoulderRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: trailingWing.maxX, y: body.minY - shoulderRadius),
            control: CGPoint(x: trailingWing.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: trailingWing.maxX, y: 0))
        path.addLine(to: CGPoint(x: core.maxX, y: 0))
        path.addLine(to: CGPoint(x: core.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: core.minX, y: body.minY))
        path.closeSubpath()
        return path
    }
}
