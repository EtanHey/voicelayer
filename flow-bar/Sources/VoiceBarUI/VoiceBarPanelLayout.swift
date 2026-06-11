import CoreGraphics

public struct VoiceBarPanelLayout: Equatable {
    public var panelSize: CGSize
    public var activeHitRect: CGRect
    public var lowerBodyRect: CGRect
    public var topFusionRect: CGRect

    public var bodySize: CGSize {
        lowerBodyRect.size
    }

    public func containsActivePoint(_ point: CGPoint) -> Bool {
        lowerBodyRect.contains(point) || topFusionRect.contains(point)
    }

    public static func make(
        mode: VoiceMode,
        isCollapsed: Bool,
        previewText: String?,
        statusText: String = "",
        notchClosedSize: CGSize? = nil,
        idleAccessoryButtonCount: Int = 0,
        queueItemCount: Int = 0,
        isPasteFlowActive: Bool = false,
        padding: CGFloat
    ) -> VoiceBarPanelLayout {
        if isCollapsed, let notchClosedSize {
            let rect = CGRect(origin: .zero, size: notchClosedSize)
            return VoiceBarPanelLayout(
                panelSize: notchClosedSize,
                activeHitRect: rect.insetBy(dx: 2, dy: 2),
                lowerBodyRect: rect,
                topFusionRect: CGRect(
                    x: 0,
                    y: max(0, notchClosedSize.height - 1),
                    width: notchClosedSize.width,
                    height: 1
                )
            )
        }

        let contentSize = contentSize(
            mode: mode,
            isCollapsed: isCollapsed,
            previewText: previewText,
            statusText: statusText,
            notchClosedSize: notchClosedSize,
            idleAccessoryButtonCount: idleAccessoryButtonCount,
            queueItemCount: queueItemCount
        )
        let safePadding = max(0, padding)
        let resolvedContentSize = if isPasteFlowActive, !isCollapsed {
            CGSize(
                width: Theme.panelWidth - (safePadding * 2),
                height: contentSize.height
            )
        } else {
            contentSize
        }
        let bodySize = CGSize(
            width: resolvedContentSize.width + (safePadding * 2),
            height: resolvedContentSize.height + (safePadding * 2)
        )
        let sideRadius = max(0, Theme.notchSideRadius)
        let fusionHeight = max(0, Theme.notchFusionBandHeight)
        let panelSize = CGSize(
            width: bodySize.width + (sideRadius * 2),
            height: bodySize.height + fusionHeight
        )
        let lowerBodyRect = CGRect(
            x: sideRadius,
            y: 0,
            width: bodySize.width,
            height: bodySize.height
        )
        let topFusionRect = CGRect(
            x: 0,
            y: bodySize.height,
            width: panelSize.width,
            height: fusionHeight
        )
        let hitInset: CGFloat = 2
        let horizontalInset = min(hitInset, max(0, resolvedContentSize.width / 2))
        let verticalInset = min(hitInset, max(0, resolvedContentSize.height / 2))
        let activeHitRect = CGRect(
            x: sideRadius + safePadding + horizontalInset,
            y: safePadding + verticalInset,
            width: max(1, resolvedContentSize.width - (horizontalInset * 2)),
            height: max(1, resolvedContentSize.height - (verticalInset * 2))
        )

        return VoiceBarPanelLayout(
            panelSize: panelSize,
            activeHitRect: activeHitRect,
            lowerBodyRect: lowerBodyRect,
            topFusionRect: topFusionRect
        )
    }

    private static func contentSize(
        mode: VoiceMode,
        isCollapsed: Bool,
        previewText: String?,
        statusText: String,
        notchClosedSize: CGSize?,
        idleAccessoryButtonCount: Int,
        queueItemCount: Int
    ) -> CGSize {
        if isCollapsed {
            return notchClosedSize ?? CGSize(width: Theme.notchIslandWidth, height: Theme.notchFusionBandHeight)
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
}
