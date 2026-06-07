// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
//
// Follows the user's mouse across multiple monitors.
// .nonactivatingPanel MUST be in the styleMask at init time (FB16484811).

import AppKit
import SwiftUI

public final class PillHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitRectProvider: (() -> NSRect)?

    override public func hitTest(_ point: NSPoint) -> NSView? {
        if let activeHitRectProvider, !activeHitRectProvider().contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}

public final class FloatingPillPanel: NSPanel {
    public var contextMenuProvider: (() -> NSMenu)?
    public var rightClickAction: (() -> Bool)?
    public var escapeAction: (() -> Bool)?
    public var activeHitRectProvider: (() -> NSRect)?
    public var mouseEventPassThroughPoster: ((NSEvent) -> Void)?
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
        level = .floating // above normal windows
        becomesKeyOnlyIfNeeded = true // don't eagerly grab key

        // --- Visibility ---
        hidesOnDeactivate = false // stay visible when app loses focus
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
        if event.type == .keyDown, event.keyCode == 53, escapeAction?() == true {
            return
        }

        if shouldPassThroughMouseEvent(event) {
            passMouseEventThrough(event)
            return
        }

        if event.type == .rightMouseDown {
            if rightClickAction?() == true {
                return
            }
            if let contentView,
               let menu = contextMenuProvider?() {
                NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                return
            }
        }

        if event.type == .leftMouseDown {
            let startedInVisiblePill = activeHitRectContains(pointInWindow: event.locationInWindow)
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

    public func activeHitRectContains(pointInWindow: NSPoint) -> Bool {
        guard let activeHitRectProvider else { return true }
        let point = contentView?.convert(pointInWindow, from: nil) ?? pointInWindow
        return activeHitRectProvider().contains(point)
    }

    public func shouldPassThroughMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            !activeHitRectContains(pointInWindow: event.locationInWindow)
        default:
            false
        }
    }

    private func passMouseEventThrough(_ event: NSEvent) {
        ignoresMouseEvents = true
        if let mouseEventPassThroughPoster {
            mouseEventPassThroughPoster(event)
        } else if let cgEvent = event.cgEvent?.copy() {
            cgEvent.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.ignoresMouseEvents = false
        }
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
        verticalOffset: CGFloat? = nil,
        menuBarAttached: Bool = false,
        menuBarProfile: VoiceBarMenuBarDisplayProfile = .flat
    ) {
        let target = screen ?? screenContainingMouse() ?? NSScreen.main
        guard let target else { return }
        let visible = target.visibleFrame // excludes Dock & menu bar
        let fullFrame = target.frame
        let size = frame.size
        let x = if menuBarAttached {
            VoiceBarMenuBarGeometry.attachedOriginX(
                screenFrame: fullFrame,
                visibleFrame: visible,
                panelWidth: size.width,
                horizontalOffset: horizontalOffset,
                profile: menuBarProfile
            )
        } else {
            visible.origin.x + (visible.width * horizontalOffset) - (size.width / 2)
        }
        let y: CGFloat = if let vOffset = verticalOffset {
            visible.origin.y + (visible.height * vOffset) - (size.height / 2)
        } else if menuBarAttached {
            VoiceBarMenuBarGeometry.attachedOriginY(
                screenFrame: fullFrame,
                visibleFrame: visible,
                panelHeight: size.height,
                fallbackTopPadding: Theme.topPadding,
                profile: menuBarProfile
            )
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
