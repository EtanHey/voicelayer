// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
//
// Follows the user's mouse across multiple monitors.
// .nonactivatingPanel MUST be in the styleMask at init time (FB16484811).

import AppKit
import SwiftUI

public final class PillHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitRectProvider: (() -> NSRect)?

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let activeHitRectProvider, !activeHitRectProvider().contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}

public final class FloatingPillPanel: NSPanel {
    public var contextMenuProvider: (() -> NSMenu)?
    public var activeHitRectProvider: (() -> NSRect)?
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
    public override var canBecomeKey: Bool {
        true
    }

    /// Override sendEvent to handle right-click context menu.
    /// Note: removed makeKey() on left click — it was stealing focus from the
    /// user's active app. .nonactivatingPanel + canBecomeKey=true is sufficient
    /// for SwiftUI buttons to respond without activation.
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown,
           let contentView,
           let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }

        if event.type == .leftMouseDown {
            dragStartWasInVisiblePill = activeHitRectProvider?().contains(event.locationInWindow) ?? true
        } else if event.type == .leftMouseDragged, dragStartWasInVisiblePill {
            performDrag(with: event)
            return
        } else if event.type == .leftMouseUp {
            dragStartWasInVisiblePill = false
        }

        super.sendEvent(event)
    }

    public override var canBecomeMain: Bool {
        false
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
