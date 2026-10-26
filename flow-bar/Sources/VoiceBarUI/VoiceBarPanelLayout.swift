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
    public let interactiveHitRect: CGRect
    public let hoverExpansionRect: CGRect
    public let hoverRetentionRect: CGRect

    private let interactionRegion: VoiceBarNotchHitRegion
    private let controlRegion: VoiceBarNotchHitRegion
    private let visibleRegion: VoiceBarNotchVisibleRegion
    private let localHoverCoreRect: CGRect

    public static func make(
        presentation: VoiceBarNotchPresentation,
        canvasGeometry: VoiceBarNotchGeometry? = nil,
        shadowOutsets: VoiceBarNotchShadowOutsets = .material
    ) -> VoiceBarPanelLayout {
        make(
            presentation: presentation,
            interactionConfiguration: .fallback(for: presentation),
            canvasGeometry: canvasGeometry,
            shadowOutsets: shadowOutsets
        )
    }

    public static func make(
        presentation: VoiceBarNotchPresentation,
        interactionConfiguration: VoiceBarNotchInteractionConfiguration,
        canvasGeometry: VoiceBarNotchGeometry? = nil,
        shadowOutsets: VoiceBarNotchShadowOutsets = .material
    ) -> VoiceBarPanelLayout {
        let geometry = presentation.geometry
        let canvasGeometry = canvasGeometry ?? geometry
        let contentOffsetX = canvasGeometry.coreOriginX - geometry.coreOriginX
        let contentOffsetY = canvasGeometry.totalHeight - geometry.totalHeight
        let visibleContentRect = CGRect(
            x: shadowOutsets.leading + contentOffsetX,
            y: shadowOutsets.bottom + contentOffsetY,
            width: geometry.totalWidth,
            height: geometry.totalHeight
        )
        let interactionRegion = VoiceBarNotchHitRegion(
            geometry: geometry,
            configuration: interactionConfiguration
        )
        let interactiveHitRect = interactionRegion.bounds.offsetBy(
            dx: visibleContentRect.minX,
            dy: visibleContentRect.minY
        )
        let visibleRegion = VoiceBarNotchVisibleRegion(presentation: presentation)
        let localHoverCoreRect = CGRect(
            x: geometry.coreOriginX,
            y: geometry.lowerSurfaceHeight,
            width: geometry.coreWidth,
            height: geometry.topHeight
        )
        let interactionBounds = interactionRegion.bounds
        let hoverExpansionRect = (interactionBounds.isEmpty
            ? localHoverCoreRect
            : localHoverCoreRect.union(interactionBounds))
            .offsetBy(dx: visibleContentRect.minX, dy: visibleContentRect.minY)
        let panelSize = CGSize(
            width: canvasGeometry.totalWidth + shadowOutsets.leading + shadowOutsets.trailing,
            height: canvasGeometry.totalHeight + shadowOutsets.bottom
        )
        let hoverRetentionRect = hoverExpansionRect
            .insetBy(
                dx: -Self.hoverRetentionPadding,
                dy: -Self.hoverRetentionPadding
            )
            .intersection(CGRect(origin: .zero, size: panelSize))

        return VoiceBarPanelLayout(
            presentation: presentation,
            panelSize: panelSize,
            visibleContentRect: visibleContentRect,
            interactiveHitRect: interactiveHitRect,
            hoverExpansionRect: hoverExpansionRect,
            hoverRetentionRect: hoverRetentionRect,
            interactionRegion: interactionRegion,
            controlRegion: VoiceBarNotchHitRegion(geometry: geometry, configuration: .init(
                leadingControlCount: interactionConfiguration.leadingControlCount,
                trailingControlCountFromCore: interactionConfiguration.trailingControlCountFromCore,
                trailingControlCountFromOuter: interactionConfiguration.trailingControlCountFromOuter,
                trailingOuterInset: interactionConfiguration.trailingOuterInset,
                lowerControlCount: interactionConfiguration.lowerControlCount
            )),
            visibleRegion: visibleRegion,
            localHoverCoreRect: localHoverCoreRect
        )
    }

    public func containsInteractiveContent(_ point: CGPoint) -> Bool {
        containsControl(point) || (containsVisibleSurface(point) && interactionRegion.contains(
            CGPoint(
                x: point.x - visibleContentRect.minX,
                y: point.y - visibleContentRect.minY
            )
        ))
    }

    public func containsControl(_ point: CGPoint) -> Bool {
        controlRegion.contains(CGPoint(x: point.x - visibleContentRect.minX,
                                      y: point.y - visibleContentRect.minY))
    }

    public func containsHoverExpansion(_ point: CGPoint) -> Bool {
        let localPoint = CGPoint(
            x: point.x - visibleContentRect.minX,
            y: point.y - visibleContentRect.minY
        )
        return localHoverCoreRect.contains(localPoint) || interactionRegion.contains(localPoint)
    }

    public func containsVisibleSurface(_ point: CGPoint) -> Bool {
        visibleRegion.contains(
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

/// NOTCH2: the AppKit hit providers' view of the notch while the shell animates. SwiftUI draws an interpolated
/// shell, but AppKit only knows the destination layout, so a note band that has not been drawn yet could claim
/// clicks (and stop passing them to the app underneath). While a same-size change settles, a point counts only
/// if both the previous and the destination layouts contain it. Every interpolated frame covers that overlap,
/// so a claimed point is always drawn. A size change moves the window itself, so it applies the destination as
/// before.
public struct VoiceBarPanelHitGate: Equatable {
    /// Hard retention deadline, anchored to the first change and never extended by reversals.
    public static let settleDuration: TimeInterval = 0.5

    public private(set) var layout: VoiceBarPanelLayout
    /// Layouts the shell may still be drawn between. Surface admission uses their intersection;
    /// actual control tracking uses their union for at most 500 ms (eight unique layouts maximum).
    public private(set) var settlingFrom: [VoiceBarPanelLayout] = []
    public private(set) var settlesAt: TimeInterval = 0

    public init(layout: VoiceBarPanelLayout) {
        self.layout = layout
    }

    /// Returns true when the layout changed, so the caller can refresh the window's event gate.
    @discardableResult
    public mutating func update(to next: VoiceBarPanelLayout, now: TimeInterval) -> Bool {
        let expired = !settlingFrom.isEmpty && now >= settlesAt
        if expired { settlingFrom.removeAll() }
        guard next != layout else { return expired }
        if next.presentation.geometry == layout.presentation.geometry {
            // Only the interaction configuration changed; nothing is animating.
        } else if next.panelSize == layout.panelSize {
            if settlingFrom.isEmpty { settlesAt = now + Self.settleDuration }
            if !settlingFrom.contains(layout) {
                settlingFrom.append(layout)
                // Bound storage even for a stream of distinct geometries.
                if settlingFrom.count > 8 { settlingFrom.removeFirst() }
            }
        } else {
            settlingFrom = []
        }
        layout = next
        return true
    }

    public func isSettling(now: TimeInterval) -> Bool {
        !settlingFrom.isEmpty && now < settlesAt
    }

    public func containsVisibleSurface(_ point: CGPoint, now: TimeInterval) -> Bool {
        layout.containsVisibleSurface(point) &&
            (!isSettling(now: now) || settlingFrom.allSatisfy { $0.containsVisibleSurface(point) })
    }

    /// Preserve AppKit mouse-moved/tooltip tracking over controls during shell transitions.
    /// The surrounding transparent canvas retains the conservative visible-surface gate.
    public func containsMouseTrackingSurface(_ point: CGPoint, now: TimeInterval) -> Bool {
        containsVisibleSurface(point, now: now) || containsTrackedControl(point, now: now)
    }

    public func containsInteractiveContent(_ point: CGPoint, now: TimeInterval) -> Bool {
        layout.containsInteractiveContent(point) || containsTrackedControl(point, now: now)
    }

    private func containsTrackedControl(_ point: CGPoint, now: TimeInterval) -> Bool {
        layout.containsControl(point) ||
            (isSettling(now: now) && settlingFrom.contains { $0.containsControl(point) })
    }
}

public enum VoiceBarIsolatedCapturePlacement {
    public static let environmentVariable = "QA_VOICEBAR_CAPTURE_BOTTOM_LEFT"
    public static let topRightEnvironmentVariable = "QA_VOICEBAR_CAPTURE_TOP_RIGHT"
    public static let offscreenEnvironmentVariable = "QA_VOICEBAR_CAPTURE_OFFSCREEN"
    public static let parallelInstanceEnvironmentVariable = "VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE"
    public static let cornerInset: CGFloat = 24
    public static let offscreenOrigin: CGFloat = -20000

    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        (environment[environmentVariable] == "1" ||
            environment[topRightEnvironmentVariable] == "1" ||
            environment[offscreenEnvironmentVariable] == "1") &&
            environment[parallelInstanceEnvironmentVariable] == "1"
    }

    public static func frame(
        panelSize: CGSize,
        visibleFrame: CGRect,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CGRect {
        if environment[offscreenEnvironmentVariable] == "1" {
            return CGRect(
                x: offscreenOrigin - cornerInset - panelSize.width,
                y: offscreenOrigin - cornerInset - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        }
        if environment[topRightEnvironmentVariable] == "1" {
            return CGRect(
                x: visibleFrame.maxX - cornerInset - panelSize.width,
                y: visibleFrame.maxY - cornerInset - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        }
        return CGRect(
            x: visibleFrame.minX + cornerInset,
            y: visibleFrame.minY + cornerInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Keep every state inside one teleprompter-sized capture envelope while
    /// allowing the real AppKit window to shrink to the visible state. The
    /// top edge and hardware-core center stay invariant across the resize.
    public static func frame(
        layout: VoiceBarPanelLayout,
        visibleFrame: CGRect,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CGRect {
        let referencePresentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: true,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false,
            coreWidth: layout.presentation.geometry.coreWidth,
            visibleCoreOcclusionInset: layout.presentation.visibleCoreOcclusionInset
        )
        let referenceCanvas = VoiceBarNotchMorphCanvasLayout.resolve(
            for: referencePresentation
        )
        let referenceLayout = VoiceBarPanelLayout.make(
            presentation: referencePresentation,
            canvasGeometry: referenceCanvas.canvasGeometry
        )
        let referenceFrame = frame(
            panelSize: referenceLayout.panelSize,
            visibleFrame: visibleFrame,
            environment: environment
        )
        let referenceCoreMidX = referenceFrame.minX +
            referenceLayout.visibleContentRect.minX +
            referencePresentation.geometry.coreMidX
        let localCoreMidX = layout.visibleContentRect.minX +
            layout.presentation.geometry.coreMidX

        return CGRect(
            x: referenceCoreMidX - localCoreMidX,
            y: referenceFrame.maxY - layout.panelSize.height,
            width: layout.panelSize.width,
            height: layout.panelSize.height
        )
    }
}
