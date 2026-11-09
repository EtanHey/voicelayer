import CoreGraphics
import SwiftUI

public struct VoiceBarNotchInteractionConfiguration: Equatable, Sendable {
    public let leadingControlCount: Int
    public let trailingControlCountFromCore: Int
    public let trailingControlCountFromOuter: Int
    public let trailingOuterInset: CGFloat
    public let lowerControlCount: Int
    /// The whole lower surface takes clicks, hover and scroll (the History panel's rows).
    public let lowerSurfaceIsInteractive: Bool
    /// T6: the outermost leading control may be wider than a slot (the reading speed chip); it grows outward.
    public let leadingOutermostControlWidth: CGFloat?
    /// T4/T7: one more lower control one pitch past the centred group's trailing edge (Stop or X), outside its centring.
    public let lowerTerminalControl: Bool
    /// The lower row's bottom edge, from the body's bottom.
    public let lowerControlBottomInset: CGFloat

    public init(
        leadingControlCount: Int = 0,
        trailingControlCountFromCore: Int = 0,
        trailingControlCountFromOuter: Int = 0,
        trailingOuterInset: CGFloat = VoiceBarNotchContract.material.compactContentInset,
        lowerControlCount: Int = 0,
        lowerSurfaceIsInteractive: Bool = false,
        leadingOutermostControlWidth: CGFloat? = nil,
        lowerTerminalControl: Bool = false,
        lowerControlBottomInset: CGFloat = 14
    ) {
        self.leadingControlCount = max(0, leadingControlCount)
        self.trailingControlCountFromCore = max(0, trailingControlCountFromCore)
        self.trailingControlCountFromOuter = max(0, trailingControlCountFromOuter)
        self.trailingOuterInset = max(0, trailingOuterInset)
        self.lowerControlCount = max(0, lowerControlCount)
        self.lowerSurfaceIsInteractive = lowerSurfaceIsInteractive
        self.leadingOutermostControlWidth = leadingOutermostControlWidth.map { max(0, $0) }
        self.lowerTerminalControl = lowerTerminalControl
        self.lowerControlBottomInset = max(0, lowerControlBottomInset)
    }

    /// The History panel: the launcher's buttons stay live (History closes it again) and the body is live.
    /// 2.3 U2: the left wing carries the mic and its chevron.
    public static let historyPanel = VoiceBarNotchInteractionConfiguration(
        leadingControlCount: 2,
        trailingControlCountFromCore: 2,
        lowerSurfaceIsInteractive: true
    )

    public static let none = VoiceBarNotchInteractionConfiguration()

    /// The same band controls over a live drawer body (0510 R3: a drawer under the recording or status wings).
    public var withInteractiveLowerSurface: Self {
        VoiceBarNotchInteractionConfiguration(
            leadingControlCount: leadingControlCount, trailingControlCountFromCore: trailingControlCountFromCore,
            trailingControlCountFromOuter: trailingControlCountFromOuter, trailingOuterInset: trailingOuterInset,
            lowerControlCount: lowerControlCount, lowerSurfaceIsInteractive: true
        )
    }

    /// Compatibility for geometry-only callers. The app installs a complete
    /// operational configuration so optional controls are never inferred from
    /// wing width or stale view state.
    public static func fallback(
        for presentation: VoiceBarNotchPresentation
    ) -> VoiceBarNotchInteractionConfiguration {
        switch presentation.visualState {
        case .idle:
            .none
        case .hoverLauncher:
            VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 2,
                trailingControlCountFromCore: 2
            )
        case .recording:
            VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 2
            )
        case .compactStatus:
            .none
        case .teleprompter:
            VoiceBarNotchInteractionConfiguration(lowerControlCount: 1)
        case .history:
            presentation.bandState == .recording
                ? VoiceBarNotchInteractionConfiguration(leadingControlCount: 2).withInteractiveLowerSurface
                : presentation.bandState == .compactStatus
                ? VoiceBarNotchInteractionConfiguration.none.withInteractiveLowerSurface
                : .historyPanel
        }
    }
}

public struct VoiceBarNotchHitRegion: Equatable {
    public let rects: [CGRect]

    public init(
        geometry: VoiceBarNotchGeometry,
        configuration: VoiceBarNotchInteractionConfiguration
    ) {
        let material = VoiceBarNotchContract.material
        let size = material.compactControlSize
        let pitch = size + material.compactControlSpacing
        let topY = geometry.lowerSurfaceHeight + ((geometry.topHeight - size) / 2)
        var rects: [CGRect] = []

        for index in 0 ..< configuration.leadingControlCount {
            let isOutermost = index == configuration.leadingControlCount - 1
            let width = isOutermost ? max(size, configuration.leadingOutermostControlWidth ?? size) : size
            rects.append(
                CGRect(
                    x: geometry.coreOriginX
                        - VoiceBarNotchContract.compactCoreContentInset
                        - size
                        - (CGFloat(index) * pitch)
                        - (width - size),
                    y: topY,
                    width: width,
                    height: size
                )
            )
        }

        for index in 0 ..< configuration.trailingControlCountFromCore {
            rects.append(
                CGRect(
                    x: geometry.coreOriginX
                        + geometry.coreWidth
                        + VoiceBarNotchContract.compactCoreContentInset
                        + (CGFloat(index) * pitch),
                    y: topY,
                    width: size,
                    height: size
                )
            )
        }

        for index in 0 ..< configuration.trailingControlCountFromOuter {
            rects.append(
                CGRect(
                    x: geometry.topOriginX
                        + geometry.topWidth
                        - configuration.trailingOuterInset
                        - size
                        - (CGFloat(index) * pitch),
                    y: topY,
                    width: size,
                    height: size
                )
            )
        }

        if configuration.lowerControlCount > 0 {
            let lowerPitch = size + 10
            let rowWidth = (CGFloat(configuration.lowerControlCount) * size)
                + (CGFloat(configuration.lowerControlCount - 1) * 10)
            let rowOriginX = (geometry.totalWidth - rowWidth) / 2
            for index in 0 ..< configuration.lowerControlCount {
                rects.append(
                    CGRect(
                        x: rowOriginX + (CGFloat(index) * lowerPitch),
                        y: configuration.lowerControlBottomInset,
                        width: size,
                        height: size
                    )
                )
            }
            if configuration.lowerTerminalControl {
                rects.append(
                    CGRect(
                        x: rowOriginX + rowWidth + 10,
                        y: configuration.lowerControlBottomInset,
                        width: size,
                        height: size
                    )
                )
            }
        }

        if configuration.lowerSurfaceIsInteractive, geometry.lowerSurfaceHeight > 0 {
            rects.append(CGRect(
                x: geometry.bodyOriginX,
                y: 0,
                width: geometry.bodyWidth,
                height: geometry.lowerSurfaceHeight
            ))
        }

        self.rects = rects
    }

    public var bounds: CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    public func contains(_ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }
}

public struct VoiceBarNotchVisibleRegion: Equatable {
    public let presentation: VoiceBarNotchPresentation

    public init(presentation: VoiceBarNotchPresentation) {
        self.presentation = presentation
    }

    public var bounds: CGRect {
        CGRect(origin: .zero, size: CGSize(
            width: presentation.geometry.totalWidth,
            height: presentation.geometry.totalHeight
        ))
    }

    public func contains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }

        let geometry = presentation.geometry
        // AppKit reports window-local points from the lower-left while the
        // SwiftUI shape contract renders from the upper-left.
        let renderedPoint = CGPoint(
            x: point.x,
            y: geometry.totalHeight - point.y
        )
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        if layout.coreRect.contains(renderedPoint) {
            return true
        }
        return VoiceBarNotchContinuousShape(
            geometry: geometry,
            compactOuterCornerRadius: VoiceBarNotchContract.material
                .compactOuterCornerRadius(for: presentation.visualState),
            bodyShoulderCornerRadius: VoiceBarNotchContract.material
                .bodyShoulderCornerRadius(for: presentation.visualState)
        )
        .path(in: CGRect(origin: .zero, size: layout.totalSize))
        .contains(renderedPoint)
    }
}
