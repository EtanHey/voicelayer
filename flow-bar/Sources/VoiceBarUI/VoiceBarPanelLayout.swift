import CoreGraphics
import Foundation

public struct VoiceBarNotchShadowOutsets: Equatable, Sendable {
    public let leading: CGFloat
    public let trailing: CGFloat
    public let bottom: CGFloat

    public init(leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        self.leading = leading
        self.trailing = trailing
        self.bottom = bottom
    }

    /// The material shadow has radius 12 and a five-point downward offset.
    /// The screen-top edge deliberately has no outset so the visible core can
    /// stay physically flush with the display housing.
    public static let material = VoiceBarNotchShadowOutsets(
        leading: 12,
        trailing: 12,
        bottom: 17
    )
}

public struct VoiceBarPanelLayout: Equatable {
    public static let hoverRetentionPadding: CGFloat = 12

    public let presentation: VoiceBarNotchPresentation
    public let panelSize: CGSize
    public let visibleContentRect: CGRect
    public let activeHitRect: CGRect
    public let hoverRetentionRect: CGRect

    private let hitRegion: VoiceBarNotchHitRegion

    public static func make(
        presentation: VoiceBarNotchPresentation,
        shadowOutsets: VoiceBarNotchShadowOutsets = .material
    ) -> VoiceBarPanelLayout {
        let geometry = presentation.geometry
        let visibleContentRect = CGRect(
            x: shadowOutsets.leading,
            y: shadowOutsets.bottom,
            width: geometry.totalWidth,
            height: geometry.totalHeight
        )
        let hitRegion = VoiceBarNotchHitRegion(geometry: geometry)
        let activeHitRect = hitRegion.bounds.offsetBy(
            dx: visibleContentRect.minX,
            dy: visibleContentRect.minY
        )
        let panelSize = CGSize(
            width: geometry.totalWidth + shadowOutsets.leading + shadowOutsets.trailing,
            height: geometry.totalHeight + shadowOutsets.bottom
        )
        let hoverRetentionRect = activeHitRect
            .insetBy(
                dx: -Self.hoverRetentionPadding,
                dy: -Self.hoverRetentionPadding
            )
            .intersection(CGRect(origin: .zero, size: panelSize))

        return VoiceBarPanelLayout(
            presentation: presentation,
            panelSize: panelSize,
            visibleContentRect: visibleContentRect,
            activeHitRect: activeHitRect,
            hoverRetentionRect: hoverRetentionRect,
            hitRegion: hitRegion
        )
    }

    public func containsActiveContent(_ point: CGPoint) -> Bool {
        hitRegion.contains(
            CGPoint(
                x: point.x - visibleContentRect.minX,
                y: point.y - visibleContentRect.minY
            )
        )
    }

    public func containsHoverRetention(_ point: CGPoint) -> Bool {
        hoverRetentionRect.contains(point)
    }

    public func windowFrame(
        anchoredTo screenGeometry: VoiceBarNotchScreenGeometry
    ) -> CGRect {
        CGRect(
            x: screenGeometry.housingFrame.midX
                - (presentation.geometry.coreWidth / 2)
                - visibleContentRect.minX
                - presentation.geometry.coreOriginX,
            y: screenGeometry.screenFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

public enum VoiceBarIsolatedCapturePlacement {
    public static let environmentVariable = "QA_VOICEBAR_CAPTURE_BOTTOM_LEFT"
    public static let parallelInstanceEnvironmentVariable = "VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE"
    public static let cornerInset: CGFloat = 24

    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentVariable] == "1" &&
            environment[parallelInstanceEnvironmentVariable] == "1"
    }

    public static func frame(
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: visibleFrame.minX + cornerInset,
            y: visibleFrame.minY + cornerInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
