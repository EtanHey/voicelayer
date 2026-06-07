import CoreGraphics

public enum VoiceBarMenuBarDisplayClass: Equatable {
    case flat
    case notched
}

public struct VoiceBarMenuBarDisplayProfile: Equatable {
    public var displayClass: VoiceBarMenuBarDisplayClass
    public var notchRect: CGRect?

    public static let flat = VoiceBarMenuBarDisplayProfile(displayClass: .flat, notchRect: nil)

    public init(displayClass: VoiceBarMenuBarDisplayClass, notchRect: CGRect?) {
        self.displayClass = displayClass
        self.notchRect = notchRect
    }

    public var isNotched: Bool {
        displayClass == .notched
    }

    public var islandHeight: CGFloat {
        switch displayClass {
        case .flat:
            Theme.menuBarIslandHeight
        case .notched:
            notchRect?.height ?? Theme.menuBarIslandHeight
        }
    }

    public func islandWidth(for mode: VoiceMode, isCollapsed: Bool) -> CGFloat {
        if isCollapsed {
            return baseIdleWidth
        }

        return switch mode {
        case .idle, .disconnected:
            baseIdleWidth
        case .recording, .transcribing:
            activeWidth
        case .speaking, .error:
            expandedWidth
        }
    }

    private var baseIdleWidth: CGFloat {
        switch displayClass {
        case .flat:
            Theme.menuBarIslandFlatIdleWidth
        case .notched:
            notchRect?.width ?? Theme.menuBarIslandNotchedFallbackWidth
        }
    }

    private var activeWidth: CGFloat {
        switch displayClass {
        case .flat:
            Theme.menuBarIslandFlatActiveWidth
        case .notched:
            notchedWidth(
                leadingWing: Theme.menuBarIslandRecordingWingWidth,
                trailingWing: Theme.menuBarIslandRecordingWingWidth,
                minimum: Theme.menuBarIslandNotchedActiveMinWidth
            )
        }
    }

    private var expandedWidth: CGFloat {
        switch displayClass {
        case .flat:
            Theme.menuBarIslandFlatExpandedWidth
        case .notched:
            notchedWidth(
                leadingWing: Theme.menuBarIslandExpandedWingWidth,
                trailingWing: Theme.menuBarIslandExpandedWingWidth,
                minimum: Theme.menuBarIslandNotchedExpandedMinWidth
            )
        }
    }

    private func notchedWidth(
        leadingWing: CGFloat,
        trailingWing: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        let notchWidth = notchRect?.width ?? Theme.menuBarIslandNotchedFallbackWidth
        return max(minimum, notchWidth + (max(leadingWing, trailingWing) * 2))
    }

    public func islandContentLayout(
        for mode: VoiceMode,
        isCollapsed: Bool
    ) -> VoiceBarMenuBarIslandContentLayout {
        let width = islandWidth(for: mode, isCollapsed: isCollapsed)
        let height = islandHeight
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        guard isNotched, let notchRect else {
            let half = width / 2
            return VoiceBarMenuBarIslandContentLayout(
                bounds: bounds,
                leadingWing: CGRect(x: 0, y: 0, width: half, height: height),
                cameraSpacer: CGRect(x: half, y: 0, width: 0, height: height),
                trailingWing: CGRect(x: half, y: 0, width: width - half, height: height)
            )
        }

        let spacerWidth = notchRect.width
        let spacerX = (width - spacerWidth) / 2
        return VoiceBarMenuBarIslandContentLayout(
            bounds: bounds,
            leadingWing: CGRect(x: 0, y: 0, width: spacerX, height: height),
            cameraSpacer: CGRect(x: spacerX, y: 0, width: spacerWidth, height: height),
            trailingWing: CGRect(
                x: spacerX + spacerWidth,
                y: 0,
                width: width - spacerX - spacerWidth,
                height: height
            )
        )
    }
}

public struct VoiceBarMenuBarIslandContentLayout: Equatable {
    public var bounds: CGRect
    public var leadingWing: CGRect
    public var cameraSpacer: CGRect
    public var trailingWing: CGRect
}

public enum VoiceBarMenuBarGeometry {
    public static let notchOverdraw: CGFloat = 4
    public static let notchTopSealHeight: CGFloat = 1

    public static func displayProfile(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> VoiceBarMenuBarDisplayProfile {
        guard safeAreaTop > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else {
            return .flat
        }

        let gapMinX = left.maxX
        let gapMaxX = right.minX
        let gapWidth = gapMaxX - gapMinX
        guard gapWidth > 0 else { return .flat }

        let overdrawInset = notchOverdraw / 2
        let notchRect = CGRect(
            x: gapMinX - overdrawInset,
            y: screenFrame.maxY - safeAreaTop,
            width: gapWidth + notchOverdraw,
            height: safeAreaTop
        )
        return VoiceBarMenuBarDisplayProfile(displayClass: .notched, notchRect: notchRect)
    }

    public static func menuBarStrip(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect? {
        let stripHeight = screenFrame.maxY - visibleFrame.maxY
        guard stripHeight > 0 else { return nil }

        return CGRect(
            x: screenFrame.minX,
            y: visibleFrame.maxY,
            width: screenFrame.width,
            height: stripHeight
        )
    }

    public static func attachedOriginY(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        panelHeight: CGFloat,
        fallbackTopPadding: CGFloat,
        profile: VoiceBarMenuBarDisplayProfile = .flat
    ) -> CGFloat {
        if let notchRect = profile.notchRect {
            return notchRect.maxY - panelHeight
        }

        guard let strip = menuBarStrip(screenFrame: screenFrame, visibleFrame: visibleFrame) else {
            return visibleFrame.maxY - fallbackTopPadding - panelHeight
        }

        return strip.midY - (panelHeight / 2)
    }

    public static func attachedOriginX(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        horizontalOffset: CGFloat,
        profile: VoiceBarMenuBarDisplayProfile
    ) -> CGFloat {
        let centerX = if let notchRect = profile.notchRect {
            notchRect.midX
        } else {
            visibleFrame.origin.x + (visibleFrame.width * horizontalOffset)
        }

        return centerX - (panelWidth / 2)
    }

    public static func preferredMenuBarScreenIndex(
        profiles: [VoiceBarMenuBarDisplayProfile],
        isBuiltIn: [Bool],
        mouseScreenIndex: Int?
    ) -> Int? {
        let indexedProfiles = Array(profiles.enumerated())
        if let builtInNotched = indexedProfiles.first(where: { index, profile in
            profile.isNotched && index < isBuiltIn.count && isBuiltIn[index]
        }) {
            return builtInNotched.offset
        }

        if let notched = indexedProfiles.first(where: { $0.element.isNotched }) {
            return notched.offset
        }

        if let mouseScreenIndex,
           profiles.indices.contains(mouseScreenIndex) {
            return mouseScreenIndex
        }

        return profiles.indices.first
    }
}
