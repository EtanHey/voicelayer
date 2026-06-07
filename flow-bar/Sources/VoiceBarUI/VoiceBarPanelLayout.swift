import CoreGraphics

public struct VoiceBarPanelLayout: Equatable {
    public var panelSize: CGSize
    public var activeHitRect: CGRect

    public static func make(
        mode: VoiceMode,
        isCollapsed: Bool,
        previewText: String?,
        statusText: String = "",
        idleAccessoryButtonCount: Int = 0,
        queueItemCount: Int = 0,
        isPasteFlowActive: Bool = false,
        isHovering: Bool = false,
        isTranscriptMenuPresented: Bool = false,
        surfaceStyle: VoiceBarSurfaceStyle = .floatingPill,
        menuBarProfile: VoiceBarMenuBarDisplayProfile = .flat,
        padding: CGFloat
    ) -> VoiceBarPanelLayout {
        let contentSize = contentSize(
            mode: mode,
            isCollapsed: isCollapsed,
            previewText: previewText,
            statusText: statusText,
            idleAccessoryButtonCount: idleAccessoryButtonCount,
            queueItemCount: queueItemCount,
            isHovering: isHovering,
            isTranscriptMenuPresented: isTranscriptMenuPresented,
            surfaceStyle: surfaceStyle,
            menuBarProfile: menuBarProfile
        )
        let safePadding = surfaceStyle == .menuBarIsland || surfaceStyle == .v5Island ? 0 : max(0, padding)
        let resolvedContentSize = if isPasteFlowActive, !isCollapsed {
            CGSize(
                width: Theme.panelWidth - (safePadding * 2),
                height: contentSize.height
            )
        } else {
            contentSize
        }
        let panelSize = CGSize(
            width: resolvedContentSize.width + (safePadding * 2),
            height: resolvedContentSize.height + (safePadding * 2)
        )
        let hitInset: CGFloat = 2
        let horizontalInset = min(hitInset, max(0, resolvedContentSize.width / 2))
        let verticalInset = min(hitInset, max(0, resolvedContentSize.height / 2))
        let activeHitRect = CGRect(
            x: safePadding + horizontalInset,
            y: safePadding + verticalInset,
            width: max(1, resolvedContentSize.width - (horizontalInset * 2)),
            height: max(1, resolvedContentSize.height - (verticalInset * 2))
        )

        return VoiceBarPanelLayout(panelSize: panelSize, activeHitRect: activeHitRect)
    }

    private static func contentSize(
        mode: VoiceMode,
        isCollapsed: Bool,
        previewText: String?,
        statusText: String,
        idleAccessoryButtonCount: Int,
        queueItemCount: Int,
        isHovering: Bool,
        isTranscriptMenuPresented: Bool,
        surfaceStyle: VoiceBarSurfaceStyle,
        menuBarProfile: VoiceBarMenuBarDisplayProfile
    ) -> CGSize {
        if surfaceStyle == .menuBarIsland || surfaceStyle == .v5Island {
            return menuBarIslandContentSize(
                mode: mode,
                isCollapsed: isCollapsed,
                isHovering: isHovering,
                isTranscriptMenuPresented: isTranscriptMenuPresented,
                surfaceStyle: surfaceStyle,
                profile: menuBarProfile
            )
        }

        if isCollapsed {
            return CGSize(width: 30, height: 30)
        }

        if let previewText {
            let previewLayout = VoiceBarPresentation.transcriptPreviewLayout(for: previewText)
            return CGSize(
                width: Theme.transcriptPreviewPillWidth(for: previewText),
                height: previewLayout.height
            )
        }

        let height = mode == .speaking ? Theme.teleprompterViewportHeight : Theme.pillCompactHeight
        return CGSize(
            width: Theme.pillContentWidth(
                for: mode,
                statusText: statusText,
                idleAccessoryButtonCount: idleAccessoryButtonCount,
                queueItemCount: queueItemCount
            ),
            height: height
        )
    }

    private static func menuBarIslandContentSize(
        mode: VoiceMode,
        isCollapsed: Bool,
        isHovering: Bool,
        isTranscriptMenuPresented: Bool,
        surfaceStyle: VoiceBarSurfaceStyle,
        profile: VoiceBarMenuBarDisplayProfile
    ) -> CGSize {
        if surfaceStyle == .v5Island {
            let notchWidth = profile.notchRect?.width ?? V3Theme.previewNotchWidth
            let stripHeight = profile.islandHeight
            if isTranscriptMenuPresented {
                return CGSize(width: 716, height: stripHeight + V3Theme.menuContentHeight + 140)
            }
            let state: V3IslandState = switch mode {
            case .idle, .disconnected:
                isHovering && mode == .idle ? .hover : .idle
            case .recording, .speaking, .error:
                .recording
            case .transcribing:
                .transcribing
            }
            return V3IslandModel.layout(
                for: state,
                closedNotchWidth: notchWidth,
                stripHeight: stripHeight,
                measuredMenuHeight: stripHeight
            ).shellFrame.size
        }

        if isTranscriptMenuPresented {
            return CGSize(
                width: max(
                    Theme.menuBarTranscriptMenuWidth,
                    profile.islandWidth(for: mode, isCollapsed: isCollapsed)
                ),
                height: profile.islandHeight + Theme.menuBarTranscriptMenuHeight
            )
        }

        return CGSize(
            width: profile.islandWidth(for: mode, isCollapsed: isCollapsed),
            height: profile.islandHeight
        )
    }
}
