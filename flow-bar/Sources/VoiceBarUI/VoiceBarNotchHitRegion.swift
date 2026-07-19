import CoreGraphics

public struct VoiceBarNotchHitRegion: Equatable {
    public let rects: [CGRect]

    public init(geometry: VoiceBarNotchGeometry) {
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
        rects.contains { $0.contains(point) }
    }
}
