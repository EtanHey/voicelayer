// FloatingPanel.swift — NSPanel subclass for non-focus-stealing floating pill.
//
// Follows the user's mouse across multiple monitors.
// .nonactivatingPanel MUST be in the styleMask at init time (FB16484811).

import AppKit

final class FloatingPillPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Theme.panelWidth,
                height: 300
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
        isMovableByWindowBackground = true // pill is draggable via background
        ignoresMouseEvents = false // NOT click-through

        contentView = content
    }

    /// Allow key so SwiftUI Buttons respond to clicks.
    /// .nonactivatingPanel prevents the app from activating regardless.
    override var canBecomeKey: Bool {
        true
    }

    /// Override sendEvent to ensure first clicks pass through to SwiftUI buttons.
    /// Without this, the first tap on the collapsed dot may be consumed by the panel.
    override func sendEvent(_ event: NSEvent) {
        // Force key status before processing mouse events so buttons respond immediately
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position pill on the given screen (or the screen containing the mouse).
    /// macOS coordinates: origin at bottom-left, Y increases upward.
    /// - Parameters:
    ///   - horizontalOffset: 0.0–1.0 fraction of screen width for pill center.
    ///   - verticalOffset: 0.0–1.0 fraction of screen height for pill origin.
    ///     nil = default bottom padding.
    func positionOnScreen(
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
            visible.origin.y + (visible.height * vOffset)
        } else {
            visible.origin.y + Theme.bottomPadding
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Find which screen currently contains the mouse cursor.
    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
