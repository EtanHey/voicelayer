import CoreGraphics

public enum V3IslandMenu: Equatable {
    case history
    case terms
}

public enum V3IslandState: Equatable {
    case idle
    case hover
    case recording
    case transcribing
    case menuOpen(V3IslandMenu)

    public var menu: V3IslandMenu? {
        if case let .menuOpen(menu) = self { return menu }
        return nil
    }
}

public enum V3IslandEvent: Equatable {
    case hoverEnter
    case hoverExit
    case micClick
    case transcribeDone
    case historyClick
    case termsClick
    case grabDown(progress: CGFloat)
    case closeSheet
}

public struct V3IslandLayout: Equatable {
    public let shellFrame: CGRect
    public let visualWidth: CGFloat
    public let topCornerRadius: CGFloat
    public let bottomCornerRadius: CGFloat
    public let hardwareNotchRect: CGRect
    public let stripContentCenterY: CGFloat
    public let leftSlotFrame: CGRect
    public let micFrame: CGRect
    public let spinnerFrame: CGRect
    public let waveformFrame: CGRect
    public let buttonFrames: [CGRect]
    public let shapeBodyIntervalAtMidHeight: ClosedRange<CGFloat>
}

public struct V3IslandSheetMetrics: Equatable {
    public let stripFrame: CGRect
    public let firstRowFrame: CGRect
}

public enum V3IslandModel {
    public static let idleLeftEarWidth: CGFloat = 36
    public static let recordingLeftSlotWidth: CGFloat = 62
    public static let transcribingLeftEarWidth: CGFloat = 36
    public static let recordingRightEarWidth: CGFloat = 44
    public static let hoverRightGrowth: CGFloat = 76
    public static let buttonSize = CGSize(width: 28, height: 22)
    public static let micSize = CGSize(width: 10, height: 10)
    public static let spinnerSize = CGSize(width: 12, height: 12)

    public static func reduce(_ state: V3IslandState, event: V3IslandEvent) -> V3IslandState {
        switch (state, event) {
        case (.idle, .hoverEnter):
            .hover
        case (.hover, .hoverExit):
            .idle
        case (.idle, .micClick), (.hover, .micClick):
            .recording
        case (.recording, .micClick):
            .transcribing
        case (.transcribing, .micClick):
            .transcribing
        case (.transcribing, .transcribeDone):
            .idle
        case (.hover, .historyClick):
            .menuOpen(.history)
        case (.hover, .termsClick):
            .menuOpen(.terms)
        case (.idle, .grabDown), (.hover, .grabDown):
            .menuOpen(.history)
        case (.menuOpen, .closeSheet):
            .idle
        default:
            state
        }
    }

    public static func layout(
        for state: V3IslandState,
        closedNotchWidth: CGFloat,
        stripHeight: CGFloat,
        measuredMenuHeight: CGFloat,
        viewportWidth: CGFloat = V3Theme.menuWidth + 2 * V3Theme.radiiExpanded.top
    ) -> V3IslandLayout {
        let topRadius = topCornerRadius(for: state)
        let bottomRadius = bottomCornerRadius(for: state)
        let visualWidth = requiredVisualWidth(
            for: state,
            closedNotchWidth: closedNotchWidth,
            viewportWidth: viewportWidth
        )
        let shellWidth = visualWidth + 2 * topRadius
        let shellHeight = requiredHeight(
            for: state,
            stripHeight: stripHeight,
            measuredMenuHeight: measuredMenuHeight
        )
        let leftWing = leftWingWidth(for: state)
        let centerY = stripHeight / 2
        let hardwareNotchRect = CGRect(
            x: topRadius + leftWing,
            y: 0,
            width: closedNotchWidth,
            height: stripHeight
        )
        let leftSlotFrame = CGRect(
            x: topRadius,
            y: 0,
            width: leftWing,
            height: stripHeight
        )
        let micFrame = CGRect(
            x: leftSlotFrame.midX - micSize.width / 2,
            y: centerY - micSize.height / 2,
            width: micSize.width,
            height: micSize.height
        )
        let spinnerFrame = CGRect(
            x: leftSlotFrame.midX - spinnerSize.width / 2,
            y: centerY - spinnerSize.height / 2,
            width: spinnerSize.width,
            height: spinnerSize.height
        )
        let waveformFrame = CGRect(
            x: hardwareNotchRect.maxX + (recordingRightEarWidth - V3Theme.barSlotWidth) / 2,
            y: centerY - 8,
            width: V3Theme.barSlotWidth,
            height: 16
        )
        let buttonY = centerY - buttonSize.height / 2
        let historyFrame = CGRect(
            x: hardwareNotchRect.maxX + 4,
            y: buttonY,
            width: buttonSize.width,
            height: buttonSize.height
        )
        let termsFrame = CGRect(
            x: historyFrame.maxX + 4,
            y: buttonY,
            width: buttonSize.width,
            height: buttonSize.height
        )
        let buttonFrames = state == .hover ? [historyFrame, termsFrame] : []

        // §6: V3NotchShape insets the body by topCornerRadius at mid-height.
        // Frame width therefore includes 2×topR so the body covers the S2
        // hardware rect and avoids light-menu-bar slivers.
        let bodyInterval = topRadius ... (shellWidth - topRadius)

        return V3IslandLayout(
            shellFrame: CGRect(x: 0, y: 0, width: shellWidth, height: shellHeight),
            visualWidth: visualWidth,
            topCornerRadius: topRadius,
            bottomCornerRadius: bottomRadius,
            hardwareNotchRect: hardwareNotchRect,
            stripContentCenterY: centerY,
            leftSlotFrame: leftSlotFrame,
            micFrame: micFrame,
            spinnerFrame: spinnerFrame,
            waveformFrame: waveformFrame,
            buttonFrames: buttonFrames,
            shapeBodyIntervalAtMidHeight: bodyInterval
        )
    }

    public static func requiredVisualWidth(
        for state: V3IslandState,
        closedNotchWidth: CGFloat,
        viewportWidth: CGFloat = V3Theme.menuWidth + 2 * V3Theme.radiiExpanded.top
    ) -> CGFloat {
        switch state {
        case .idle:
            closedNotchWidth + idleLeftEarWidth
        case .hover:
            closedNotchWidth + idleLeftEarWidth + hoverRightGrowth
        case .recording:
            closedNotchWidth + recordingLeftSlotWidth + recordingRightEarWidth
        case .transcribing:
            closedNotchWidth + transcribingLeftEarWidth
        case .menuOpen:
            max(1, viewportWidth - (2 * V3Theme.radiiExpanded.top))
        }
    }

    public static func requiredHeight(
        for state: V3IslandState,
        stripHeight: CGFloat,
        measuredMenuHeight: CGFloat
    ) -> CGFloat {
        switch state {
        case .idle, .hover, .recording, .transcribing:
            stripHeight
        case .menuOpen:
            measuredMenuHeight
        }
    }

    public static func resolvedStripHeight(
        actualScreenSafeAreaTop: CGFloat,
        visibleMenuBarHeight: CGFloat,
        fallbackPreviewHeight: CGFloat = V3Theme.previewNotchHeight
    ) -> CGFloat {
        if actualScreenSafeAreaTop > 0 { return actualScreenSafeAreaTop }
        if visibleMenuBarHeight > 0 { return visibleMenuBarHeight }
        return fallbackPreviewHeight
    }

    public static func sheetMetrics(
        stripHeight: CGFloat,
        horizontalPadding: CGFloat,
        rowVerticalPadding: CGFloat,
        firstRowTextHeight: CGFloat
    ) -> V3IslandSheetMetrics {
        let rowHeight = firstRowTextHeight + (2 * rowVerticalPadding)
        return V3IslandSheetMetrics(
            stripFrame: CGRect(x: 0, y: 0, width: 1, height: stripHeight),
            firstRowFrame: CGRect(
                x: horizontalPadding,
                y: stripHeight + 6,
                width: 1,
                height: rowHeight
            )
        )
    }

    public static func topCornerRadius(for state: V3IslandState) -> CGFloat {
        switch state {
        case .hover:
            V3Theme.radiiPeek.top
        case .menuOpen:
            V3Theme.radiiExpanded.top
        case .idle, .recording, .transcribing:
            V3Theme.radiiClosed.top
        }
    }

    public static func bottomCornerRadius(for state: V3IslandState) -> CGFloat {
        switch state {
        case .hover:
            V3Theme.radiiPeek.bottom
        case .menuOpen:
            V3Theme.radiiExpanded.bottom
        case .idle, .recording, .transcribing:
            V3Theme.radiiClosed.bottom
        }
    }

    public static func leftWingWidth(for state: V3IslandState) -> CGFloat {
        switch state {
        case .idle, .hover:
            idleLeftEarWidth
        case .recording:
            recordingLeftSlotWidth
        case .transcribing:
            transcribingLeftEarWidth
        case .menuOpen:
            0
        }
    }
}
