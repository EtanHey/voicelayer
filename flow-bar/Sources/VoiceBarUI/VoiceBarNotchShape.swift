import CoreGraphics
import SwiftUI

public enum VoiceBarNotchSide: Equatable, Sendable {
    case leading
    case trailing
}

public struct VoiceBarNotchShapeLayout: Equatable {
    public let geometry: VoiceBarNotchGeometry
    public let inverseJoinRadius: CGFloat
    /// How far each visible wing's glass runs in under the housing (UXP-2). The housing's lower corners are
    /// rounded, so a wing that stopped at the core's edge left an unpainted pocket beside each corner. The glass
    /// still never reaches the housing's middle.
    public let housingTuck: CGFloat

    public init(
        geometry: VoiceBarNotchGeometry,
        inverseJoinRadius: CGFloat = VoiceBarNotchContract.material.inverseJoinRadius,
        housingTuck: CGFloat = VoiceBarNotchContract.material.hardwareCoreLowerCornerRadius
    ) {
        self.geometry = geometry
        self.inverseJoinRadius = inverseJoinRadius
        self.housingTuck = housingTuck
    }

    /// The housing cut-out the glass leaves open: the core, narrowed by the tuck on each side that has a wing.
    public var housingCutout: CGRect {
        let leading = geometry.leadingWingWidth > 0 ? housingTuck : 0
        let trailing = geometry.trailingWingWidth > 0 ? housingTuck : 0
        return CGRect(
            x: coreRect.minX + leading,
            y: 0,
            width: max(0, coreRect.width - leading - trailing),
            height: geometry.topHeight
        )
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
    public var coreAnchorX: CGFloat?

    public init(
        geometry: VoiceBarNotchGeometry,
        compactOuterCornerRadius: CGFloat = 11,
        coreAnchorX: CGFloat? = nil
    ) {
        self.geometry = geometry
        self.compactOuterCornerRadius = compactOuterCornerRadius
        self.coreAnchorX = coreAnchorX
    }

    /// The outer radius is animated with the geometry (Lane C follow-up): as a plain stored value it jumped to
    /// the destination state's radius on the first frame of every morph.
    public var animatableData: AnimatablePair<VoiceBarNotchGeometryAnimatableData, CGFloat> {
        get { AnimatablePair(VoiceBarNotchGeometryAnimatableData(geometry: geometry), compactOuterCornerRadius) }
        set {
            geometry = newValue.first.geometry
            compactOuterCornerRadius = newValue.second
        }
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

        // Geometry values are already expressed in screen points. During a
        // morph AppKit can commit the destination host bounds before SwiftUI
        // finishes interpolating this path; scaling to those bounds pins one
        // edge and stretches the other. Preserve point-space dimensions so
        // the caller's core-alignment offset can grow both sides together.
        let transform = CGAffineTransform(
            translationX: rect.minX + (coreAnchorX ?? geometry.coreOriginX) - geometry.coreOriginX,
            y: rect.minY
        )
        return path.applying(transform)
    }

    private func compactPath(layout: VoiceBarNotchShapeLayout) -> Path {
        var path = Path()
        let cutout = layout.housingCutout
        if layout.leadingWingRect.width > 0 {
            let wing = layout.leadingWingRect
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .leading,
                    outerCornerRadius: compactOuterCornerRadius
                )
                .path(in: CGRect(x: wing.minX, y: wing.minY, width: cutout.minX - wing.minX, height: wing.height))
            )
        }
        if layout.trailingWingRect.width > 0 {
            let wing = layout.trailingWingRect
            path.addPath(
                VoiceBarNotchWingShape(
                    side: .trailing,
                    outerCornerRadius: compactOuterCornerRadius
                )
                .path(in: CGRect(x: cutout.maxX, y: wing.minY, width: wing.maxX - cutout.maxX, height: wing.height))
            )
        }
        return path
    }

    private func continuousBodyPath(layout: VoiceBarNotchShapeLayout) -> Path {
        let body = layout.bodyRect
        let leadingWing = layout.leadingWingRect
        let trailingWing = layout.trailingWingRect
        let core = layout.housingCutout
        // A shoulder can only be as deep as the body sticks out past its wing: a body flush with the wing
        // (History, UXP-2) continues the wing's side straight down.
        let leadingShoulderRadius = min(
            layout.inverseJoinRadius,
            leadingWing.width,
            layout.geometry.topHeight,
            max(0, leadingWing.minX - body.minX)
        )
        let trailingShoulderRadius = min(
            layout.inverseJoinRadius,
            trailingWing.width,
            layout.geometry.topHeight,
            max(0, body.maxX - trailingWing.maxX)
        )
        // With both sides flush the corner may reach up into the wings, so a panel one point tall keeps the
        // wings' rounded corners instead of squaring them off.
        let isFlush = leadingShoulderRadius == 0 && trailingShoulderRadius == 0
        let lowerRadius = min(
            compactOuterCornerRadius,
            body.width / 2,
            isFlush ? (body.maxY / 2) : (body.height / 2)
        )
        var path = Path()

        path.move(to: CGPoint(x: core.minX, y: 0))
        path.addLine(to: CGPoint(x: leadingWing.minX, y: 0))
        path.addLine(to: CGPoint(x: leadingWing.minX, y: body.minY - leadingShoulderRadius))
        path.addQuadCurve(
            to: CGPoint(x: leadingWing.minX - leadingShoulderRadius, y: body.minY),
            control: CGPoint(x: leadingWing.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX + leadingShoulderRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.minY + leadingShoulderRadius),
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
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + trailingShoulderRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - trailingShoulderRadius, y: body.minY),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: trailingWing.maxX + trailingShoulderRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: trailingWing.maxX, y: body.minY - trailingShoulderRadius),
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
