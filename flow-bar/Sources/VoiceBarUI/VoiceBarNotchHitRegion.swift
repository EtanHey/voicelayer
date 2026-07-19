import CoreGraphics
import SwiftUI

public struct VoiceBarNotchHitRegion: Equatable {
    public let rects: [CGRect]
    private let geometry: VoiceBarNotchGeometry

    public init(geometry: VoiceBarNotchGeometry) {
        self.geometry = geometry
        let topRect = CGRect(
            x: geometry.topOriginX,
            y: geometry.lowerSurfaceHeight,
            width: geometry.topWidth,
            height: geometry.topHeight
        )
        if geometry.lowerSurfaceHeight > 0 {
            let bodyRect = CGRect(
                x: geometry.bodyOriginX,
                y: 0,
                width: geometry.bodyWidth,
                height: geometry.lowerSurfaceHeight
            )
            rects = [topRect, bodyRect]
        } else {
            rects = [topRect]
        }
    }

    public var bounds: CGRect {
        rects.reduce(.null) { $0.union($1) }
    }

    public func contains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }

        // AppKit reports window-local points from the lower-left while the
        // SwiftUI shape contract renders from the upper-left. Hit-test the
        // exact rendered path after flipping Y, then union the physical camera
        // housing so hovering the real notch can still summon the launcher.
        let renderedPoint = CGPoint(
            x: point.x,
            y: geometry.totalHeight - point.y
        )
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        if layout.coreRect.contains(renderedPoint) {
            return true
        }
        return VoiceBarNotchContinuousShape(
            geometry: geometry,
            compactOuterCornerRadius: VoiceBarNotchContract.material
                .compactOuterCornerRadius(for: visualState)
        )
        .path(in: CGRect(origin: .zero, size: layout.totalSize))
        .contains(renderedPoint)
    }

    private var visualState: VoiceBarNotchVisualState {
        if geometry.lowerSurfaceHeight > 0 {
            return .teleprompter
        }
        if geometry.leadingWingWidth == 0, geometry.trailingWingWidth == 0 {
            return .idle
        }
        if geometry.leadingWingWidth == VoiceBarNotchContract
            .geometry(for: .hoverLauncher).leadingWingWidth,
            geometry.trailingWingWidth == VoiceBarNotchContract
            .geometry(for: .hoverLauncher).trailingWingWidth {
            return .hoverLauncher
        }
        return .recording
    }
}
