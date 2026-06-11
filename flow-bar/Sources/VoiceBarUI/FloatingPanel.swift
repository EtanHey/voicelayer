// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
//
// Follows the user's mouse across multiple monitors.
// .nonactivatingPanel MUST be in the styleMask at init time (FB16484811).

import AppKit
import SwiftUI

public final class PillHostingView<Content: View>: NSHostingView<Content> {
    public var activeHitRectProvider: (() -> NSRect)?
    public var activeHitTestProvider: ((NSPoint) -> Bool)?

    override public func hitTest(_ point: NSPoint) -> NSView? {
        if let activeHitTestProvider, !activeHitTestProvider(point) {
            return nil
        }
        if let activeHitRectProvider, !activeHitRectProvider().contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}

public final class FloatingPillPanel: NSPanel {
    public var contextMenuProvider: (() -> NSMenu)?
    public var activeHitRectProvider: (() -> NSRect)?

    public init(content: NSView) {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: max(content.frame.width, 1),
                height: max(content.frame.height, 1)
            ),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        styleMask.insert([.nonactivatingPanel, .utilityWindow, .hudWindow])

        // --- Floating behaviour ---
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        becomesKeyOnlyIfNeeded = false

        // --- Visibility ---
        hidesOnDeactivate = false // stay visible when app loses focus
        isReleasedWhenClosed = false // keep in memory for reuse
        collectionBehavior = [
            .canJoinAllSpaces, // visible on every Space
            .fullScreenAuxiliary, // visible over full-screen apps
            .stationary, // don't move with Spaces transitions
            .ignoresCycle,
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

    override public var canBecomeKey: Bool {
        false
    }

    /// Override sendEvent to handle right-click context menu.
    /// Note: removed makeKey() on left click — it was stealing focus from the
    /// user's active app. .nonactivatingPanel + canBecomeKey=true is sufficient
    /// for SwiftUI buttons to respond without activation.
    override public func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown,
           let contentView,
           let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }

        super.sendEvent(event)
    }

    override public var canBecomeMain: Bool {
        false
    }

    public func shouldHandlePillDrag(startedInVisiblePill: Bool) -> Bool {
        false
    }

    public func positionAsNotchApp(on screen: NSScreen? = nil) {
        let target = screen ?? screenContainingMouse() ?? NSScreen.main
        guard let target else { return }
        let metrics = NotchAppScreenMetrics(screen: target)
        setFrame(NotchAppGeometry.frame(for: frame.size, on: metrics), display: true)
    }

    /// Find which screen currently contains the mouse cursor.
    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
