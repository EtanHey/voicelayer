// FlowBarApp.swift — Entry point for Voice Bar.
//
// Wires together: VoiceState, SocketServer, FloatingPillPanel, BarView.
// No Dock icon (.accessory activation policy). Menu bar icon for status + quit.
// Tracks mouse across screens — pill follows the cursor.
//
// AIDEV-NOTE: Architecture inversion (Phase 0) — FlowBar is the persistent
// server on /tmp/voicelayer.sock. MCP servers connect as clients.
// All discovery file logic removed (no more polling, no file watchers).

import AppKit
import SwiftUI

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let voiceState = VoiceState()
    private var socketServer: SocketServer?
    private var panel: FloatingPillPanel?
    private var mouseMonitor: Any?
    private var moveObserver: Any?
    /// Track which screen the pill is on to avoid unnecessary repositioning.
    private var currentScreenIndex: Int = -1
    /// Saved offsets (0.0–1.0) for pill positioning on screen.
    private var horizontalOffset: CGFloat = Theme.horizontalOffset
    private var verticalOffset: CGFloat? // nil = use default bottomPadding

    /// Last reported pill size — used to avoid layout loops.
    private var lastPillSize: CGSize = .zero

    private static let horizontalOffsetKey = "voicebar.horizontalOffset"
    private static let verticalOffsetKey = "voicebar.verticalOffset"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon (LSUIElement equivalent)
        NSApp.setActivationPolicy(.accessory)

        // Request Accessibility permission (needed for CGEvent paste-on-record-end).
        // Shows the macOS permission dialog on first launch.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOptions)
        NSLog("[FlowBar] Accessibility trusted: %@", trusted ? "YES" : "NO — paste will not work")

        // Socket server — listens on /tmp/voicelayer.sock
        let server = SocketServer(state: voiceState)
        socketServer = server

        // Wire the send-command closure so BarView buttons -> socket -> MCP clients
        voiceState.sendCommand = { [weak server] cmd in
            server?.sendToAll(command: cmd)
        }

        server.start()

        // Resize panel dynamically when pill content changes
        voiceState.onPillSizeChange = { [weak self] size in
            DispatchQueue.main.async {
                self?.resizePanelToFit(size)
            }
        }

        // Floating pill
        let barView = BarView(state: voiceState)
        let hosting = NSHostingView(rootView: barView)
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: Theme.panelWidth,
            height: 300
        )

        // Load saved position
        if let saved = UserDefaults.standard.object(forKey: Self.horizontalOffsetKey) as? Double {
            horizontalOffset = max(0.05, min(0.95, CGFloat(saved)))
        }
        if let saved = UserDefaults.standard.object(forKey: Self.verticalOffsetKey) as? Double {
            verticalOffset = max(0.0, min(0.95, CGFloat(saved)))
        }

        let pill = FloatingPillPanel(content: hosting)
        pill.positionOnScreen(
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
        pill.orderFront(nil)
        panel = pill

        // Save position when user drags the pill
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: pill,
            queue: .main
        ) { [weak self] _ in
            self?.savePanelPosition()
        }

        // Track mouse across screens — move pill to whichever monitor the cursor is on
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running as a menu-bar agent
    }

    // MARK: - Dynamic panel sizing

    /// Resize the panel to tightly fit the pill content, anchored at bottom-center.
    /// Called via onPillSizeChange callback from the SwiftUI GeometryReader.
    private func resizePanelToFit(_ pillSize: CGSize) {
        guard let panel else { return }
        // Avoid layout loops — only resize on meaningful change
        let epsilon: CGFloat = 2
        if abs(pillSize.width - lastPillSize.width) < epsilon,
           abs(pillSize.height - lastPillSize.height) < epsilon {
            return
        }
        lastPillSize = pillSize

        let padding = Theme.panelPadding
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)

        // Anchor at visual center — pill stays in place across state changes
        let oldFrame = panel.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY
        let newFrame = NSRect(
            x: centerX - newWidth / 2,
            y: centerY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Mouse tracking

    /// Reposition pill when mouse moves to a different screen.
    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        // Capture screens array once to avoid TOCTOU race if a display disconnects.
        let screens = NSScreen.screens
        guard let targetScreen = screens.firstIndex(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) else { return }

        // Only reposition when the screen actually changes
        if targetScreen != currentScreenIndex {
            currentScreenIndex = targetScreen
            panel?.positionOnScreen(
                screens[targetScreen],
                horizontalOffset: horizontalOffset,
                verticalOffset: verticalOffset
            )
        }
    }

    // MARK: - Drag persistence

    /// Save the pill's position as percentages of screen dimensions.
    private func savePanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let hOffset = (panel.frame.midX - visible.origin.x) / visible.width
        let vOffset = (panel.frame.origin.y - visible.origin.y) / visible.height
        horizontalOffset = max(0.05, min(0.95, CGFloat(hOffset)))
        verticalOffset = max(0.0, min(0.95, CGFloat(vOffset)))
        UserDefaults.standard.set(Double(horizontalOffset), forKey: Self.horizontalOffsetKey)
        UserDefaults.standard.set(Double(verticalOffset!), forKey: Self.verticalOffsetKey)
    }
}

// MARK: - SwiftUI App entry point

@main
struct FlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra("VoiceBar", systemImage: "waveform.circle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appDelegate.voiceState.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(appDelegate.voiceState.isConnected ? "Connected" : "Disconnected")
                        .font(.system(.caption, weight: .medium))
                }
                Divider()
                Button("Quit Voice Bar") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(8)
        }

        // Empty Settings scene satisfies the "at least one Scene" requirement
        Settings {
            EmptyView()
        }
    }
}
