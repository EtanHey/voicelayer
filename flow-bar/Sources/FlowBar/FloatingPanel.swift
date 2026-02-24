/// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
///
/// Follows the user's mouse across multiple monitors.
///
/// AIDEV-NOTE: .nonactivatingPanel MUST be in the styleMask at init time.
/// Setting it later has a known bug (FB16484811) where the WindowServer
/// tag doesn't update. This is why we use a custom NSPanel subclass
/// instead of configuring an NSWindow after creation.

import AppKit

final class FloatingPillPanel: NSPanel {

    init(content: NSView) {
        // .nonactivatingPanel MUST be in the styleMask at init time.
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Theme.pillMaxWidth,
                height: Theme.pillHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // --- Floating behaviour ---
        isFloatingPanel = true
        level = .floating                     // above normal windows
        becomesKeyOnlyIfNeeded = true         // don't eagerly grab key

        // --- Visibility ---
        hidesOnDeactivate = false             // stay visible when app loses focus
        isReleasedWhenClosed = false          // keep in memory for reuse
        collectionBehavior = [
            .canJoinAllSpaces,                // visible on every Space
            .fullScreenAuxiliary,             // visible over full-screen apps
            .stationary                       // don't move with Spaces transitions
        ]
        animationBehavior = .utilityWindow

        // --- Transparent chrome ---
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                     // SwiftUI adds its own shadow

        // --- Interaction ---
        isMovableByWindowBackground = false
        ignoresMouseEvents = false            // NOT click-through

        contentView = content
    }

    // Allow key so SwiftUI Buttons respond to clicks.
    // .nonactivatingPanel prevents the app from activating regardless.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Position pill at bottom of the given screen (or the screen containing the mouse).
    /// macOS coordinates: origin at bottom-left, Y increases upward.
    func positionOnScreen(_ screen: NSScreen? = nil) {
        let target = screen ?? screenContainingMouse() ?? NSScreen.main
        guard let target else { return }
        let visible = target.visibleFrame          // excludes Dock & menu bar
        let size    = frame.size
        let x = visible.origin.x + (visible.width * Theme.horizontalOffset) - (size.width / 2)
        let y = visible.origin.y + Theme.bottomPadding
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Find which screen currently contains the mouse cursor.
    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
