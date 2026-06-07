import CoreGraphics

public struct V5IslandPanelEnvelope: Equatable {
    public let frame: CGRect
    public let maxShellHeight: CGFloat

    public static func make(screenFrame: CGRect) -> V5IslandPanelEnvelope {
        let height = max(V3Theme.previewNotchHeight, screenFrame.height * 0.45)
        return V5IslandPanelEnvelope(
            frame: CGRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - height,
                width: screenFrame.width,
                height: height
            ),
            maxShellHeight: height
        )
    }

    public static func activeHitRect(
        screenWidth: CGFloat,
        notchWidth: CGFloat,
        stripHeight: CGFloat,
        maxShellHeight: CGFloat,
        isMenuPresented: Bool,
        measuredMenuHeight: CGFloat
    ) -> CGRect {
        let state: V3IslandState = isMenuPresented ? .menuOpen(.history) : .hover
        let shellHeight = clampedShellHeight(
            measuredMenuHeight: measuredMenuHeight,
            stripHeight: stripHeight,
            maxShellHeight: maxShellHeight,
            isMenuPresented: isMenuPresented
        )
        let viewportWidth = visibleShellViewportWidth(
            screenWidth: screenWidth,
            notchWidth: notchWidth,
            isMenuPresented: isMenuPresented
        )
        let layout = V3IslandModel.layout(
            for: state,
            closedNotchWidth: notchWidth,
            stripHeight: stripHeight,
            measuredMenuHeight: shellHeight,
            viewportWidth: viewportWidth
        )
        let x = (screenWidth - layout.shellFrame.width) / 2
        return CGRect(x: x, y: 0, width: layout.shellFrame.width, height: shellHeight)
    }

    public static func visibleShellViewportWidth(
        screenWidth: CGFloat,
        notchWidth: CGFloat,
        isMenuPresented: Bool
    ) -> CGFloat {
        guard isMenuPresented else { return screenWidth }
        return min(screenWidth, max(716, notchWidth + 2 * V3Theme.radiiExpanded.top))
    }

    public static func clampedShellHeight(
        measuredMenuHeight: CGFloat,
        stripHeight: CGFloat,
        maxShellHeight: CGFloat,
        isMenuPresented: Bool
    ) -> CGFloat {
        guard isMenuPresented else { return stripHeight }
        return min(maxShellHeight, max(stripHeight, measuredMenuHeight))
    }
}
