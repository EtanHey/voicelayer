// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
//
// Follows the user's mouse across multiple monitors.
// .nonactivatingPanel MUST be in the styleMask at init time (FB16484811).

import AppKit
import SwiftUI

public enum VoiceBarBackingScaleReadiness: Equatable {
    case waitingForScreen
    case rerasterize(targetScale: CGFloat)
    case ready(scale: CGFloat)

    public static func evaluate(
        screenScale: CGFloat?,
        windowScale: CGFloat,
        contentScale: CGFloat?,
        descendantScales: [CGFloat] = []
    ) -> Self {
        guard let screenScale, screenScale > 0 else { return .waitingForScreen }
        let tolerance: CGFloat = 0.01
        guard abs(windowScale - screenScale) <= tolerance,
              let contentScale,
              abs(contentScale - screenScale) <= tolerance,
              descendantScales.allSatisfy({ abs($0 - screenScale) <= tolerance })
        else {
            return .rerasterize(targetScale: screenScale)
        }
        return .ready(scale: screenScale)
    }
}

public enum VoiceBarBackingScaleSynchronizer {
    @discardableResult
    public static func synchronize(_ view: NSView, to scale: CGFloat) -> CGFloat? {
        guard scale > 0 else { return view.layer?.contentsScale }
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        apply(scale, to: view.layer)
        view.needsDisplay = true
        view.displayIfNeeded()
        return view.layer?.contentsScale
    }

    public static func layerScales(in view: NSView) -> [CGFloat] {
        layerScales(in: view.layer)
    }

    private static func apply(_ scale: CGFloat, to layer: CALayer?) {
        guard let layer else { return }
        layer.contentsScale = scale
        layer.sublayers?.forEach { apply(scale, to: $0) }
        // N12: only a layer that owns its drawing is asked to draw again. One whose contents were handed to it
        // has nothing to draw with, so `setNeedsDisplay()` empties it. SwiftUI's SF Symbol `ImageLayer` is such
        // a layer (every symbol on macOS 27, the bitmap ones on macOS 26): SwiftUI refills it only when that one
        // glyph next changes. This pass runs after every panel layout change, so the drawer's tab icons vanished
        // until their tab was selected.
        guard canRedraw(layer) else { return }
        layer.setNeedsDisplay()
    }

    /// Redraw ownership, not what the contents are: the layer's class draws (`display()` or `draw(in:)` is
    /// overridden) or its delegate does (`display(_:)` or `draw(_:in:)`). Such a layer is re-rendered at the new
    /// scale even when it currently holds an image. Measured on macOS 26.5 and 27.0: SwiftUI's `ImageLayer`
    /// overrides neither and its `_SwiftUILayerDelegate` implements neither; its text `CGDrawingLayer` overrides
    /// `draw(in:)`.
    static func canRedraw(_ layer: CALayer) -> Bool {
        let layerClass: AnyClass = type(of: layer)
        for selector in [#selector(CALayer.display), #selector(CALayer.draw(in:))]
            where class_getMethodImplementation(layerClass, selector)
            != class_getMethodImplementation(CALayer.self, selector) {
            return true
        }
        guard let delegate = layer.delegate else { return false }
        return delegate.responds(to: #selector(CALayerDelegate.display(_:)))
            || delegate.responds(to: #selector(CALayerDelegate.draw(_:in:)))
    }

    private static func layerScales(in layer: CALayer?) -> [CGFloat] {
        guard let layer else { return [] }
        return [layer.contentsScale] + (layer.sublayers ?? []).flatMap {
            layerScales(in: $0)
        }
    }
}

public final class PillHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitTestProvider: ((NSPoint) -> Bool)?
    public var renderedSurfaceHitTestProvider: ((NSPoint) -> Bool)?
    public var hoverExpansionHitTestProvider: ((NSPoint) -> Bool)?
    public var hoverRetentionHitTestProvider: ((NSPoint) -> Bool)?
    public var onHoverChanged: ((Bool) -> Void)?
    public var onPointerMoved: ((NSPoint) -> Void)?

    private var hoverHysteresis = VoiceBarHoverHysteresis()
    private var hoverExitTask: Task<Void, Never>?
    private var hoverTrackingArea: NSTrackingArea?

    @discardableResult
    public func synchronizeBackingScale(to scale: CGFloat) -> CGFloat? {
        VoiceBarBackingScaleSynchronizer.synchronize(self, to: scale)
    }

    /// PILL1: accept the first mouse-down when hit testing returns this host itself (the glass
    /// between controls, via the `self` fallback below), so it acts even while another app is
    /// active. Controls answer for themselves: their hit view is the nested NSHostingView inside
    /// the glass host, which already accepts the first mouse. The nonactivating panel can still
    /// take keyboard focus without activating VoiceBar (`becomesKeyOnlyIfNeeded`); this override
    /// changes neither that nor which points `hitTest` claims.
    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let containsRenderedSurface = renderedSurfaceHitTestProvider?(point)
            ?? activeHitTestProvider?(point)
            ?? true
        guard containsRenderedSurface else {
            return nil
        }
        // Returning nil makes AppKit continue hit testing windows underneath
        // this nonactivating panel. Claim only VoiceBar's exact rendered path;
        // `self` is the fallback when SwiftUI has no child at a glass pixel.
        return super.hitTest(point) ?? self
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override public func mouseEntered(with event: NSEvent) {
        handlePointerMovement(at: event.locationInWindow)
    }

    override public func mouseMoved(with event: NSEvent) {
        handlePointerMovement(at: event.locationInWindow)
    }

    /// Provider geometry is expressed in the panel's unflipped window space,
    /// matching `NSEvent.locationInWindow` and `FloatingPillPanel` hit tests.
    public func handlePointerMovement(at point: NSPoint) {
        onPointerMoved?(point)
        updateHover(at: point)
    }

    override public func mouseExited(with _: NSEvent) {
        applyHoverEffects(
            hoverHysteresis.update(
                isInsideExpansionZone: false,
                isInsideRetentionZone: false
            )
        )
    }

    public func updateHover(at point: NSPoint) {
        applyHoverEffects(
            hoverHysteresis.update(
                isInsideExpansionZone: hoverExpansionHitTestProvider?(point) ?? false,
                isInsideRetentionZone: hoverRetentionHitTestProvider?(point) ?? false
            )
        )
    }

    private func applyHoverEffects(_ effects: [VoiceBarHoverHysteresisEffect]) {
        for effect in effects {
            switch effect {
            case let .hoverChanged(isHovering):
                onHoverChanged?(isHovering)
            case .cancelExit:
                hoverExitTask?.cancel()
                hoverExitTask = nil
            case let .scheduleExit(delay):
                hoverExitTask?.cancel()
                hoverExitTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    applyHoverEffects(hoverHysteresis.exitDelayElapsed())
                }
            }
        }
    }
}

/// R0856-12: whether the key window is one of VoiceBar's own windows other than the notch panel itself.
public enum VoiceBarWindowFocus {
    public static func holdsIdleWings(keyWindow: NSWindow?, notchPanel: NSWindow?) -> Bool {
        guard let keyWindow, keyWindow.isVisible else { return false }
        return keyWindow !== notchPanel
    }
}

public final class FloatingPillPanel: NSPanel {
    public var contextMenuProvider: (() -> NSMenu)?
    public var activeHitTestProvider: ((NSPoint) -> Bool)?
    public var contextMenuHitTestProvider: ((NSPoint) -> Bool)?
    public var isPillDragEnabled = true
    private var dragStartWasInVisiblePill = false

    public init(content: NSView) {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: max(content.frame.width, 1),
                height: max(content.frame.height, 1)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // --- Floating behaviour ---
        isFloatingPanel = true
        level = .statusBar // physically occupies the menu-bar / housing region
        becomesKeyOnlyIfNeeded = true // don't eagerly grab key

        // --- Visibility ---
        hidesOnDeactivate = false // stay visible when app loses focus
        // U1: as a regular app, Hide VoiceBar (⌘H, the Dock menu's Hide) hides Settings, not the notch. The notch
        // hides only through "Hide for 1 hour".
        canHide = false
        isReleasedWhenClosed = false // keep in memory for reuse
        collectionBehavior = [
            .canJoinAllSpaces, // visible on every Space
            .fullScreenAuxiliary, // visible over full-screen apps
            .stationary, // don't move with Spaces transitions
        ]
        animationBehavior = .utilityWindow

        // --- Transparent chrome ---
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // SwiftUI adds its own shadow

        // --- Interaction ---
        isMovableByWindowBackground = false
        ignoresMouseEvents = false // NOT click-through
        acceptsMouseMovedEvents = true
        // PILL1: VoiceBar is usually not the active app, so the controls' `.help` tooltips need this.
        allowsToolTipsWhenApplicationIsInactive = true

        contentView = content
    }

    /// Allow key so SwiftUI Buttons respond to clicks.
    /// .nonactivatingPanel prevents the app from activating regardless.
    override public var canBecomeKey: Bool {
        true
    }

    /// Override sendEvent to handle right-click context menu.
    /// Note: removed makeKey() on left click — it was stealing focus from the
    /// user's active app. .nonactivatingPanel + canBecomeKey=true is sufficient
    /// for SwiftUI buttons to respond without activation.
    override public func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown,
           shouldHandleContextMenu(at: event.locationInWindow),
           let contentView,
           let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }

        if event.type == .leftMouseDown {
            let startedInVisiblePill = startsDrag(at: event.locationInWindow)
            dragStartWasInVisiblePill = shouldHandlePillDrag(startedInVisiblePill: startedInVisiblePill)
        } else if event.type == .leftMouseDragged,
                  shouldHandlePillDrag(startedInVisiblePill: dragStartWasInVisiblePill) {
            performDrag(with: event)
            return
        } else if event.type == .leftMouseUp {
            dragStartWasInVisiblePill = false
        }

        super.sendEvent(event)
    }

    override public var canBecomeMain: Bool {
        false
    }

    public func shouldHandlePillDrag(startedInVisiblePill: Bool) -> Bool {
        isPillDragEnabled && startedInVisiblePill
    }

    /// Shared by the resident app and UIE2E host: notch gestures must never move the whole window.
    public func configureNotchDragging(screenKind: VoiceBarNotchScreenKind, allowsFreeDrag: Bool, mode: VoiceMode) {
        if screenKind == .flatDisplayFallback {
            isPillDragEnabled = false
            isMovableByWindowBackground = false
            return
        }
        let usesPhysicalHousing = screenKind == .hardwareNotch
        let pillDragEnabled = !usesPhysicalHousing && allowsFreeDrag
        let movableByWindowBackground = !usesPhysicalHousing && allowsFreeDrag
            && VoiceBarPresentation.isPanelDraggable(mode: mode)
        if isPillDragEnabled != pillDragEnabled { isPillDragEnabled = pillDragEnabled }
        if isMovableByWindowBackground != movableByWindowBackground {
            isMovableByWindowBackground = movableByWindowBackground
        }
    }

    public func startsDrag(at point: NSPoint) -> Bool {
        activeHitTestProvider?(point) ?? true
    }

    public func shouldHandleContextMenu(at point: NSPoint) -> Bool {
        contextMenuHitTestProvider?(point)
            ?? activeHitTestProvider?(point)
            ?? true
    }

    /// Position pill on the given screen (or the screen containing the mouse).
    /// macOS coordinates: origin at bottom-left, Y increases upward.
    /// - Parameters:
    ///   - horizontalOffset: 0.0–1.0 fraction of screen width for pill center.
    ///   - verticalOffset: 0.0–1.0 fraction of screen height for pill center.
    ///     nil = fixed top-center island placement.
    public func positionOnScreen(
        _ screen: NSScreen? = nil,
        horizontalOffset: CGFloat = Theme.horizontalOffset,
        verticalOffset: CGFloat? = nil
    ) {
        let target = screen ?? screenContainingMouse() ?? NSScreen.main
        guard let target else { return }
        let visible = target.visibleFrame // excludes Dock & menu bar
        let size = frame.size
        let x = visible.origin.x + (visible.width * horizontalOffset) - (size.width / 2)
        let y: CGFloat = if let vOffset = verticalOffset {
            visible.origin.y + (visible.height * vOffset) - (size.height / 2)
        } else {
            visible.maxY - Theme.topPadding - size.height
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Find which screen currently contains the mouse cursor.
    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
