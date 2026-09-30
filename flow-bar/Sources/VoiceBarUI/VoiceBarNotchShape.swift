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
    /// The convex corner where a lower body steps out past its wing (`bodyShoulderCornerRadius(for:)`).
    public var bodyShoulderCornerRadius: CGFloat
    public var coreAnchorX: CGFloat?

    public init(
        geometry: VoiceBarNotchGeometry,
        compactOuterCornerRadius: CGFloat = 11,
        bodyShoulderCornerRadius: CGFloat = VoiceBarNotchContract.material.inverseJoinRadius,
        coreAnchorX: CGFloat? = nil
    ) {
        self.geometry = geometry
        self.compactOuterCornerRadius = compactOuterCornerRadius
        self.bodyShoulderCornerRadius = bodyShoulderCornerRadius
        self.coreAnchorX = coreAnchorX
    }

    /// The radii are animated with the geometry (Lane C follow-up): as plain stored values they jumped to the
    /// destination state's radius on the first frame of every morph.
    public var animatableData: AnimatablePair<
        VoiceBarNotchGeometryAnimatableData, AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                VoiceBarNotchGeometryAnimatableData(geometry: geometry),
                AnimatablePair(compactOuterCornerRadius, bodyShoulderCornerRadius)
            )
        }
        set {
            geometry = newValue.first.geometry
            compactOuterCornerRadius = newValue.second.first
            bodyShoulderCornerRadius = newValue.second.second
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
        let leading = sideProfile(
            layout: layout, wingWidth: leadingWing.width, step: leadingWing.minX - body.minX
        )
        let trailing = sideProfile(
            layout: layout, wingWidth: trailingWing.width, step: body.maxX - trailingWing.maxX
        )
        var path = Path()

        // One closed outline: down the leading side, along the bottom, back up the trailing side, then around
        // the housing cut-out. `d` is how far a point sits outside its wing's outer side.
        path.move(to: CGPoint(x: core.minX, y: 0))
        path.addLine(to: CGPoint(x: leadingWing.minX, y: 0))
        for segment in leading {
            let end = CGPoint(x: leadingWing.minX - segment.end.x, y: segment.end.y)
            if let control = segment.control {
                path.addQuadCurve(to: end, control: CGPoint(x: leadingWing.minX - control.x, y: control.y))
            } else {
                path.addLine(to: end)
            }
        }
        var ends = [CGPoint(x: 0, y: 0)] + trailing.map(\.end)
        ends.removeLast()
        path.addLine(to: CGPoint(x: trailingWing.maxX + (trailing.last?.end.x ?? 0), y: body.maxY))
        for (segment, start) in zip(trailing, ends).reversed() {
            let end = CGPoint(x: trailingWing.maxX + start.x, y: start.y)
            if let control = segment.control {
                path.addQuadCurve(to: end, control: CGPoint(x: trailingWing.maxX + control.x, y: control.y))
            } else {
                path.addLine(to: end)
            }
        }
        path.addLine(to: CGPoint(x: core.maxX, y: 0))
        path.addLine(to: CGPoint(x: core.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: core.minX, y: body.minY))
        path.closeSubpath()
        return path
    }

    /// One outer side of the shell, top to bottom, as (d, y) points: d = 0 is the wing's outer side and d = `step`
    /// the body's. A straight line when `control` is nil, else a quad curve.
    private typealias SideSegment = (end: CGPoint, control: CGPoint?)

    private func sideProfile(
        layout: VoiceBarNotchShapeLayout, wingWidth: CGFloat, step rawStep: CGFloat
    ) -> [SideSegment] {
        let body = layout.bodyRect
        let step = max(0, rawStep)
        let bodyCorner = min(compactOuterCornerRadius, body.width / 2)
        // The concave join under the wing and the convex corner of the step-out. Neither can be deeper than
        // the step, and a side with no wing has no shoulder at all.
        let join = min(layout.inverseJoinRadius, wingWidth, layout.geometry.topHeight, step / 2)
        let shoulderTarget = bodyShoulderCornerRadius
            * min(1, layout.inverseJoinRadius > 0 ? wingWidth / layout.inverseJoinRadius : 0)
        // A body flush with its wing (or barely past it) rounds its bottom corner up into the wing, so a panel
        // one point tall keeps the wing's rounded corner instead of squaring it off.
        let reachesIntoWing = step < bodyCorner
        let lower = min(bodyCorner, (reachesIntoWing ? body.maxY : body.height) / 2)
        let cornerTop = body.maxY - lower

        if reachesIntoWing, cornerTop < body.minY, lower > 0 {
            // The bottom corner starts above the step, so it swallows it: follow the wing's side down to the
            // corner's curve and join it there.
            let t = (step / lower).squareRoot()
            return [
                (CGPoint(x: 0, y: body.maxY - lower * (1 - t) * (1 - t)), nil),
                (CGPoint(x: step - lower, y: body.maxY), CGPoint(x: step - lower * t, y: body.maxY)),
            ]
        }
        let shoulder = max(0, min(shoulderTarget, step - join, cornerTop - body.minY))
        return [
            (CGPoint(x: 0, y: body.minY - join), nil),
            (CGPoint(x: join, y: body.minY), CGPoint(x: 0, y: body.minY)),
            (CGPoint(x: step - shoulder, y: body.minY), nil),
            (CGPoint(x: step, y: body.minY + shoulder), CGPoint(x: step, y: body.minY)),
            (CGPoint(x: step, y: cornerTop), nil),
            (CGPoint(x: step - lower, y: body.maxY), CGPoint(x: step, y: body.maxY)),
        ]
    }
}
