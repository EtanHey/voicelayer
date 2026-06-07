import CoreGraphics
import Foundation
import Observation

public enum V5IslandClosePath: CaseIterable, Equatable {
    case islandTap
    case escape
    case clickOutside
    case dragUp
    case recordStart
    case anchorSwitch
}

public enum V5IslandResetReason: CaseIterable, Equatable {
    case anchorChanged
    case surfaceStyleChanged
    case toggleChanged
    case panelRecreated
}

@Observable
public final class V5IslandUIState {
    public var presentedMenu: V3IslandMenu?
    public var menuProgress: CGFloat = 0
    public var isHovering = false
    public var measuredMenuHeight: CGFloat = V3Theme.previewNotchHeight + 120
    @ObservationIgnored
    public var onPresentationChange: ((Bool) -> Void)?
    @ObservationIgnored
    public var onLayoutChange: (() -> Void)?

    public init() {}

    public var isMenuPresented: Bool {
        presentedMenu != nil
    }

    public func open(_ menu: V3IslandMenu) {
        presentedMenu = menu
        menuProgress = 1
        notifyPresentationChanged()
    }

    public func setDragProgress(_ progress: CGFloat, menu: V3IslandMenu = .history) {
        let nextProgress = min(max(progress, 0), 1.04)
        if nextProgress == 0 {
            presentedMenu = nil
        }
        guard abs(menuProgress - nextProgress) > 0.001 else { return }
        menuProgress = nextProgress
        onLayoutChange?()
    }

    public func close(_ path: V5IslandClosePath) {
        guard isMenuPresented || menuProgress != 0 else { return }
        presentedMenu = nil
        menuProgress = 0
        if path == .anchorSwitch {
            isHovering = false
        }
        notifyPresentationChanged()
    }

    public func reset(_ reason: V5IslandResetReason) {
        presentedMenu = nil
        menuProgress = 0
        isHovering = false
        measuredMenuHeight = Self.defaultMeasuredMenuHeight
        notifyPresentationChanged()
    }

    public func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        onLayoutChange?()
    }

    public func updateMeasuredMenuHeight(_ height: CGFloat) {
        let nextHeight = max(0, height)
        guard abs(measuredMenuHeight - nextHeight) > 0.5 else { return }
        measuredMenuHeight = nextHeight
        onLayoutChange?()
    }

    public func handleVoiceMode(_ mode: VoiceMode) {
        if mode == .recording || mode == .speaking {
            close(.recordStart)
        }
    }

    public static var defaultMeasuredMenuHeight: CGFloat {
        V3Theme.previewNotchHeight + 120
    }

    private func notifyPresentationChanged() {
        onPresentationChange?(isMenuPresented)
        onLayoutChange?()
    }
}

public enum V5IslandCloseAffordance {
    public static func hasTouchableAreaOutsideHardwareNotch(layout: V3IslandLayout) -> Bool {
        closeHandleRects(layout: layout).contains { rect in
            rect.width > 0 && !layout.hardwareNotchRect.contains(rect)
        }
    }

    public static func closeHandleRects(layout: V3IslandLayout) -> [CGRect] {
        let left = CGRect(
            x: 0,
            y: 0,
            width: max(0, layout.hardwareNotchRect.minX),
            height: layout.hardwareNotchRect.height
        )
        let right = CGRect(
            x: layout.hardwareNotchRect.maxX,
            y: 0,
            width: max(0, layout.shellFrame.width - layout.hardwareNotchRect.maxX),
            height: layout.hardwareNotchRect.height
        )
        return [left, right]
    }
}

public enum V5IslandHitRegion {
    public static func primaryStripRect(layout: V3IslandLayout) -> CGRect {
        let rightEdge = layout.buttonFrames.first?.minX ?? layout.shellFrame.width
        return CGRect(
            x: 0,
            y: 0,
            width: max(0, rightEdge),
            height: layout.hardwareNotchRect.height
        )
    }
}
