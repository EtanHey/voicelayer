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
        padding: CGFloat
    ) -> VoiceBarPanelLayout {
        let contentSize = contentSize(
            mode: mode,
            isCollapsed: isCollapsed,
            previewText: previewText,
            statusText: statusText,
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
        queueItemCount: Int
    ) -> CGSize {
        if isCollapsed {
            return CGSize(width: 22, height: 22)
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
