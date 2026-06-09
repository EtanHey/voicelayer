import CoreGraphics

public struct NotchIslandGeometry: Equatable {
    public static let notchWidth: CGFloat = 178
    public static let notchDepth: CGFloat = 36
    public static let sideWingWidth: CGFloat = 112
    public static let contentTopOverlap: CGFloat = 14
    public static let contentSidePadding: CGFloat = 16
    public static let contentBottomPadding: CGFloat = 6

    public var windowFrame: CGRect
    public var localBounds: CGRect
    public var notchPocket: CGRect
    public var contentRect: CGRect

    public static func make(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        contentSize: CGSize
    ) -> NotchIslandGeometry {
        let width = max(
            contentSize.width + (contentSidePadding * 2),
            notchWidth + (sideWingWidth * 2)
        )
        let height = max(
            notchDepth + contentTopOverlap + contentBottomPadding,
            contentSize.height + notchDepth - contentTopOverlap + contentBottomPadding
        )
        let windowFrame = CGRect(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
        let localBounds = CGRect(origin: .zero, size: windowFrame.size)
        let notchPocket = CGRect(
            x: localBounds.midX - (notchWidth / 2),
            y: localBounds.maxY - notchDepth,
            width: notchWidth,
            height: notchDepth
        )
        let contentRect = CGRect(
            x: localBounds.midX - (contentSize.width / 2),
            y: contentBottomPadding,
            width: contentSize.width,
            height: contentSize.height
        )

        return NotchIslandGeometry(
            windowFrame: windowFrame,
            localBounds: localBounds,
            notchPocket: notchPocket,
            contentRect: contentRect
        )
    }

    public static func panelSize(for contentSize: CGSize) -> CGSize {
        make(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            contentSize: contentSize
        ).windowFrame.size
    }

    public static func contentRect(for contentSize: CGSize) -> CGRect {
        make(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            contentSize: contentSize
        ).contentRect
    }

    public func containsActiveHitPoint(_ point: CGPoint) -> Bool {
        if notchPocket.contains(point) {
            return false
        }
        if contentRect.contains(point) {
            return true
        }

        let topWing = CGRect(
            x: localBounds.minX,
            y: notchPocket.minY,
            width: localBounds.width,
            height: notchPocket.height
        )
        return topWing.contains(point)
    }
}
