import AppKit
import CoreGraphics

public struct NotchAppScreenMetrics: Equatable {
    public var frame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxiliaryTopLeftArea: CGRect?
    public var auxiliaryTopRightArea: CGRect?

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    public init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }
}

public enum NotchAppGeometry {
    public static let fallbackClosedWidth: CGFloat = 185
    public static let minimumClosedHeight: CGFloat = 32
    public static let seamOverdraw: CGFloat = 4

    public static func closedSize(for metrics: NotchAppScreenMetrics) -> CGSize {
        let width: CGFloat = if let left = metrics.auxiliaryTopLeftArea,
                                let right = metrics.auxiliaryTopRightArea {
            max(1, metrics.frame.width - left.width - right.width + seamOverdraw)
        } else {
            fallbackClosedWidth
        }

        return CGSize(
            width: width,
            height: max(minimumClosedHeight, metrics.safeAreaTopInset)
        )
    }

    public static func frame(for size: CGSize, on metrics: NotchAppScreenMetrics) -> CGRect {
        CGRect(
            x: metrics.frame.midX - (size.width / 2),
            y: metrics.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
